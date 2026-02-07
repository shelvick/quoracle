# lib/quoracle_web/components/

## Modules
- CoreComponents: Facade module with defdelegate (33 lines)
- FormComponents: Form UI - inputs, buttons, labels, errors (279 lines)
- LayoutComponents: Layout UI - flash, headers, tables, lists (276 lines)
- UtilityComponents: Utilities - icons, JS animations, modal dialogs (184 lines)
- Layouts: App/root layout templates

## Key Functions
- FormComponents.input/1: Multi-type input field with errors
- FormComponents.button/1: Primary/danger button styles
- FormComponents.simple_form/1: Form wrapper with CSRF
- LayoutComponents.flash/1: Info/error notifications
- LayoutComponents.table/1: Responsive data tables
- LayoutComponents.header/1: Page headers with actions
- UtilityComponents.icon/1: Hero/Tabler icon rendering
- UtilityComponents.modal/1: Confirmation modal with show/hide animations
- UtilityComponents.show/2: Phoenix.LiveView.JS show transition
- UtilityComponents.hide/2: Phoenix.LiveView.JS hide transition
- UtilityComponents.translate_error/1: Ecto error translation

## Patterns
- Function components with attr/slot macros
- Tailwind CSS utility classes
- Phoenix.JS for client interactions
- HEEx templates with ~H sigil
- All public functions have @spec annotations

## Refactoring
Originally one 582-line module, split into 3 focused modules:
- FormComponents: Form-related UI
- LayoutComponents: Page structure/layout
- UtilityComponents: Shared utilities
- CoreComponents: Backward compatibility facade

## Dependencies
- Phoenix.Component
- Phoenix.HTML
- Phoenix.LiveView.JS
- Gettext for i18n