# assets/

Frontend assets for Phoenix web interface

## Files
- js/app.js: LiveView setup, WebSocket connection
- css/app.css: Tailwind imports, custom styles
- vendor/topbar.js: Progress bar for page loads
- tailwind.config.js: Tailwind configuration
- node_modules/: npm packages (gitignored)

## Build
- esbuild: ES2017 target, bundles JS to priv/static/assets/app.js (gitignored)
- Tailwind: Scans .ex/.heex, compiles CSS to priv/static/assets/app.css (gitignored)
- Heroicons: Embedded via Tailwind plugin
- Phoenix watchers: Auto-rebuild in dev