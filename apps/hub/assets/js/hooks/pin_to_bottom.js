// A scrolling thread that follows new content only while it's pinned to the
// bottom, for Blip's conversation.
//
// Pinned is a flag only the reader changes. Scrolling up yourself (wheel,
// touch, keys, the scrollbar) unpins it at once, and nothing that arrives
// afterwards moves the thread, so you can read further up while text streams
// in. Scrolling back to the bottom, or the "Jump to latest" button, pins it
// again. Layout changes the page makes on its own (content swapped, the
// thread resized) never unpin it: only a scroll up shortly after your own
// input counts.
//
// The thread gets data-pinned="true" or "false" (set as a JS command, so
// server patches keep it); a [data-pin-jump] button inside it is shown when
// unpinned (see app.css) and jumps back down.

const AT_BOTTOM = 2 // px from the bottom that still counts as at the bottom
const INTENT_MS = 1000 // how long after your input a scroll counts as yours

export default {
  mounted() {
    this.pinned = true
    this.inputAt = -Infinity
    this.mark()
    this.toBottom()

    const intent = () => { this.inputAt = performance.now() }
    this.el.addEventListener("wheel", e => {
      intent()
      if (e.deltaY < 0) this.setPinned(false)
    }, {passive: true})
    this.el.addEventListener("touchstart", intent, {passive: true})
    this.el.addEventListener("pointerdown", intent)
    this.el.addEventListener("keydown", intent)

    this.el.addEventListener("scroll", () => {
      const top = this.el.scrollTop
      const yours = performance.now() - this.inputAt < INTENT_MS
      if (yours && top < this.lastTop - 1) this.setPinned(false)
      else if (this.gap() <= AT_BOTTOM) this.setPinned(true)
      this.lastTop = top
    }, {passive: true})

    this.el.addEventListener("click", e => {
      if (!e.target.closest("[data-pin-jump]")) return
      this.setPinned(true)
      this.el.scrollTo({top: this.el.scrollHeight, behavior: "smooth"})
    })

    // New content, or the thread changing size, keeps a pinned thread at the
    // bottom; an unpinned one stays where the reader left it.
    const follow = () => { if (this.pinned) this.toBottom() }
    this.mutations = new MutationObserver(follow)
    this.mutations.observe(this.el, {childList: true, subtree: true, characterData: true})
    this.resizes = new ResizeObserver(follow)
    this.resizes.observe(this.el)
  },

  updated() { if (this.pinned) this.toBottom() },

  destroyed() {
    this.mutations.disconnect()
    this.resizes.disconnect()
  },

  gap() { return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight },

  toBottom() {
    this.el.scrollTop = this.el.scrollHeight
    this.lastTop = this.el.scrollTop
  },

  setPinned(pinned) {
    if (pinned === this.pinned) return
    this.pinned = pinned
    this.mark()
  },

  mark() { this.js().setAttribute(this.el, "data-pinned", String(this.pinned)) }
}
