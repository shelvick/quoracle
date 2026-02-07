# lib/quoracle_web/controllers/

## Modules
- PageController: Static page rendering
- PageHTML: HTML templates for pages
- ErrorHTML: Error page rendering (404, 500)
- ErrorJSON: JSON error responses

## Key Functions
- PageController.home/2: Renders landing page
- ErrorHTML.render/2: Returns error messages
- ErrorJSON.render/2: Returns error JSON

## Patterns
- Controller actions return conn
- HTML modules use embed_templates
- Error modules handle status codes

## Templates
- page_html/home.html.heex: Landing page
- error_html/*: Error pages (if added)