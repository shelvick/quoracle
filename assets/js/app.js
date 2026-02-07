// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Hooks for LiveView components
let Hooks = {}

// LogEntry hook - prevents accordion toggle when text is being selected
Hooks.LogEntry = {
  mounted() {
    this.mouseDownPos = null

    this.el.addEventListener("mousedown", (e) => {
      this.mouseDownPos = { x: e.clientX, y: e.clientY }
    })

    this.el.addEventListener("click", (e) => {
      // If user dragged more than 5px, they're selecting text - don't toggle
      if (this.mouseDownPos) {
        const dx = Math.abs(e.clientX - this.mouseDownPos.x)
        const dy = Math.abs(e.clientY - this.mouseDownPos.y)
        if (dx > 5 || dy > 5) {
          e.stopPropagation()
          e.preventDefault()
          return false
        }
      }

      // If text is selected, don't toggle
      const selection = window.getSelection()
      if (selection && selection.toString().length > 0) {
        e.stopPropagation()
        e.preventDefault()
        return false
      }
    }, true) // Capture phase to intercept before phx-click

    // Handle clipboard events from server
    this.handleEvent("copy_to_clipboard", ({text}) => {
      navigator.clipboard.writeText(text).then(() => {
        // Brief visual feedback could be added here
      }).catch(err => {
        console.error("Failed to copy:", err)
      })
    })
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket