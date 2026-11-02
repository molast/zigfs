# Web Code Guidelines

These constraints apply to all code under `zigfs-admin/web/`, in addition to the repository guidelines.

## UI Components

- The current shadcn/ui component set is already installed via `pnpm dlx shadcn@latest add --all`. Import existing local components directly; do not reinstall them for routine feature work. Preserve existing customizations when updating components.
- Match the actual filename casing in imports (for example, `@/components/ui/Button`); some existing primitives use PascalCase filenames.
- Use the project's shadcn/ui components under `src/components/ui/`. Reuse or extend shared primitives instead of introducing custom controls that merely imitate shadcn/ui styling.
- Keep pages, dialogs, and controls consistent across light and dark themes and accessible by keyboard.

## Message Notifications

- All transient feedback, including success, failure, API errors, and form validation messages, must use the shared shadcn/ui Sonner toast system.
- Toasts must appear at the **top center of the viewport** (`position="top-center"`), on desktop and mobile. Do not place them at the bottom right or override their position in individual features.
- Use `useToast()` or `useErrorToast()` from `src/components/ToastProvider.tsx`. Use the error variant for failures; never display errors as success notifications.
- Do not introduce page-top banners, inline message bars, custom notification overlays, or browser-native `alert()` dialogs as substitutes for toast feedback. Form controls may still expose `aria-invalid` and invalid styling.
- Keep a single global `ToastProvider`. Configure placement and shared notification behavior there, not in individual pages or dialogs.
- Confirmation interactions, such as confirming deletion, use the shared `ConfirmProvider`; report their outcomes through toast. Persistent help text, empty states, and task status displays are not transient notifications.

## Validation

- Run `pnpm run build` after web changes. Check relevant forms and error paths when changing interactions, including that failure feedback remains visible while a dialog is open.

## Localization

- English is the source language and default. Keep all application UI copy in `src/locales/en.json` and `src/locales/zh.json`, grouped by feature module. Both files must have identical keys and interpolation placeholders.
- Use the typed `t('module.key', { name: value })` helper. Translate complete sentences with placeholders; do not concatenate translated sentence fragments. Keep keys stable when editing copy.
- Use descriptive camelCase translation keys (for example, `navigation.objectStorage`). Do not append hashes or generated numeric suffixes. Distinguish collisions by purpose, such as `deleteTagAction` and `deleteTagConfirmation`; changing wording must not rename the key. The `labels` module retains protocol enum names for display lookup.
- Subscribe with `useLocale()` when a component renders outside the App tree. Do not evaluate translated strings once at module initialization; resolve them during rendering or through getters.
- Keep route IDs, API values, IAM Action/resource names, policy JSON, and user-provided names unchanged. Never use translated labels to drive authorization, selection, pagination, or submitted values.
- Format dates and numbers with `getFormatLocale()` and use the shared localized Calendar. Language changes must preserve form drafts and the current route.
- Run `pnpm run test:i18n` and `pnpm run build` after localization changes. Raw upstream diagnostic messages remain server-provided; translate locally authored fallback messages.
