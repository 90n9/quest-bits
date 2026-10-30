// The task Detail editor: Milkdown Crepe (ProseMirror) in the app's web view.
// Markdown goes in and comes out, so Detail stays plain markdown for the MCP server.
//
// Swift → JS (window.qb):  setMarkdown(md, docId), flush() → {docId, markdown} | null,
//                           uploadDone(id, path), uploadFailed(id)
// JS → Swift (webkit.messageHandlers.qb):
//   {type: 'ready'}                        the editor can take setMarkdown
//   {type: 'change', docId, markdown}      the user changed document docId (never on setMarkdown)
//   {type: 'height', height}               content height, to size the web view
//   {type: 'upload', id, name, mime, data} an image to save (base64); answered by uploadDone
//   {type: 'open', href}                   ⌘-click on a link: its href as written
// docId is the task the text belongs to: one editor serves every task in turn, so a change
// that arrives after the user moved on is still saved to its own task.
import { CrepeBuilder } from '@milkdown/crepe/builder'
import { blockEdit } from '@milkdown/crepe/feature/block-edit'
import { cursor } from '@milkdown/crepe/feature/cursor'
import { imageBlock } from '@milkdown/crepe/feature/image-block'
import { linkTooltip } from '@milkdown/crepe/feature/link-tooltip'
import { listItem } from '@milkdown/crepe/feature/list-item'
import { placeholder } from '@milkdown/crepe/feature/placeholder'
import { table } from '@milkdown/crepe/feature/table'
import { toolbar } from '@milkdown/crepe/feature/toolbar'
import { remarkStringifyOptionsCtx } from '@milkdown/kit/core'
import { replaceAll } from '@milkdown/kit/utils'
// Per-feature styles: the bundled style.css would also pull in KaTeX and CodeMirror.
import '@milkdown/crepe/theme/common/reset.css'
import '@milkdown/crepe/theme/common/prosemirror.css'
import '@milkdown/crepe/theme/common/block-edit.css'
import '@milkdown/crepe/theme/common/cursor.css'
import '@milkdown/crepe/theme/common/image-block.css'
import '@milkdown/crepe/theme/common/link-tooltip.css'
import '@milkdown/crepe/theme/common/list-item.css'
import '@milkdown/crepe/theme/common/placeholder.css'
import '@milkdown/crepe/theme/common/table.css'
import '@milkdown/crepe/theme/common/toolbar.css'
import './theme.css'

const post = (msg) => window.webkit?.messageHandlers?.qb?.postMessage(msg)

// Images saved by the app live in attachments/ next to the database and are stored in
// the markdown by that relative path; the web view loads them through qb-attachment:.
const ATTACHMENTS = 'attachments/'
const displayURL = (url) => (url.startsWith(ATTACHMENTS) ? 'qb-attachment:///' + url.slice(ATTACHMENTS.length) : url)

const pendingUploads = new Map()
let uploadSeq = 0

function upload(file) {
  return new Promise((resolve) => {
    const reader = new FileReader()
    // Unreadable file: an empty image block, as for a failed save (see uploadFailed).
    reader.onerror = () => resolve('')
    reader.onload = () => {
      const id = ++uploadSeq
      pendingUploads.set(id, { resolve })
      const data = String(reader.result).replace(/^data:[^,]*,/, '')
      post({ type: 'upload', id, name: file.name || 'image', mime: file.type, data })
    }
    reader.readAsDataURL(file)
  })
}

const editor = new CrepeBuilder({ root: '#app', defaultValue: '' })
  .addFeature(blockEdit)
  .addFeature(cursor)
  .addFeature(listItem)
  .addFeature(linkTooltip)
  .addFeature(table)
  .addFeature(toolbar)
  .addFeature(placeholder, { text: 'Write, or type / for blocks…', mode: 'doc' })
  .addFeature(imageBlock, {
    onUpload: upload,
    inlineOnUpload: upload,
    blockOnUpload: upload,
    proxyDomURL: displayURL,
  })

// The document shown, and the last markdown the app knows for it: what it set, or what
// was last sent. Only a different text is sent, so loading a task (even one the editor
// reformats) writes nothing.
let docId = null
let known = ''
let timer = null

// The editor's markdown without the trailing newline the serializer adds.
const current = () => editor.getMarkdown().replace(/\n+$/, '')

// The user's text when it differs from what the app knows, else null.
const unsent = () => {
  const markdown = current()
  return markdown === known ? null : markdown
}

function sendChange() {
  clearTimeout(timer)
  const markdown = unsent()
  if (markdown === null) return
  known = markdown
  post({ type: 'change', docId, markdown })
}

// Write lists with "-" like the rest of QuestBits (remark's default is "*").
editor.editor.config((ctx) => {
  ctx.update(remarkStringifyOptionsCtx, (prev) => ({ ...prev, bullet: '-' }))
})

editor.on((api) => {
  api.markdownUpdated(() => {
    clearTimeout(timer)
    timer = setTimeout(sendChange, 150)
  })
})

window.qb = {
  // Show a task's markdown. Edits not sent yet go first, to their own task. For the same
  // task (an outside write, e.g. an agent's), unsent edits win: they are sent and the
  // editor keeps them. Loading clears the undo history, so ⌘Z never brings back the
  // previous task's text.
  setMarkdown(markdown, id) {
    const sameDoc = id === docId
    const hadEdits = unsent() !== null
    sendChange()
    if (sameDoc && hadEdits) return
    docId = id
    editor.editor.action(replaceAll(markdown, true))
    known = current()
  },
  // The unsent edit, for the app to save as the editor closes; marks it sent.
  flush() {
    clearTimeout(timer)
    const markdown = unsent()
    if (markdown === null) return null
    known = markdown
    return { docId, markdown }
  },
  uploadDone(id, path) {
    pendingUploads.get(id)?.resolve(path)
    pendingUploads.delete(id)
  },
  // The app already said why (a toast). An empty image block stays in place of the
  // upload placeholder, so the user can try again or delete it.
  uploadFailed(id) {
    pendingUploads.get(id)?.resolve('')
    pendingUploads.delete(id)
  },
}

// ⌘-click opens a link (a plain click edits it, as in Notion). The href goes as written,
// so the app can tell an attachments/ link from a web link.
document.addEventListener('click', (event) => {
  const link = event.target.closest?.('a[href]')
  if (link && event.metaKey) {
    event.preventDefault()
    post({ type: 'open', href: link.getAttribute('href') })
  }
})

// A file dropped outside the text would make the web view open it in place of the editor.
const inText = (event) => event.target.closest?.('.ProseMirror')
document.addEventListener('dragover', (event) => { if (!inText(event)) event.preventDefault() })
document.addEventListener('drop', (event) => { if (!inText(event)) event.preventDefault() })

// The content's own height (not the page's, which is at least the web view's height,
// so it could only grow).
const root = document.getElementById('app')
new ResizeObserver(() => post({ type: 'height', height: Math.ceil(root.getBoundingClientRect().height) }))
  .observe(root)

editor.create().then(() => {
  known = current()
  post({ type: 'ready' })
})
