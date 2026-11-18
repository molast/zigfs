# Accessibility

## Goal and scope

ZigFS aims to make its Admin UI, documentation, and contribution workflows usable by people with
different abilities and assistive technologies. WCAG 2.2 Level AA is a design and review target for
web interfaces, not a claim that the project has completed an accessibility audit or certification.

Accessibility work includes keyboard navigation, screen reader support, readable content, zoom,
contrast, and clear feedback. Shared components help establish consistent behavior, but do not by
themselves guarantee that a page or workflow is accessible.

## Reporting a barrier

Use the [bug report form](https://github.com/molast/zigfs/issues/new?template=bug_report.yml).
Describe the task you were trying to complete and the barrier you encountered. Where possible,
include:

- The ZigFS / Admin version or commit and affected page or workflow.
- Browser and operating system versions, viewport size, zoom, and theme.
- Assistive technology and version, if relevant, such as a screen reader or voice control tool.
- Steps to reproduce, expected behavior, and actual behavior.
- A screenshot or short recording if useful, with sensitive information removed.

You do not need to disclose a disability or medical information. If the issue form is itself a
barrier, use a [blank issue](https://github.com/molast/zigfs/issues/new) with whatever information
you can provide. Follow the [security policy](SECURITY.md) for vulnerabilities rather than posting
sensitive details publicly.

## Implementation guidelines

Admin changes must follow the [contribution guide](CONTRIBUTING.md) and
[Admin Web guidelines](../zigfs-admin/web/AGENTS.md).

- Reuse or extend the shadcn/ui primitives in `zigfs-admin/web/src/components/ui/`. Fix shared
  accessibility problems in the primitive when the same pattern appears in multiple features.
- Use semantic HTML, meaningful headings, associated form labels, and accessible names for
  icon-only controls. Prefer native semantics over unnecessary ARIA.
- Make all actions available by keyboard, with a logical focus order and a visible focus indicator.
  Avoid keyboard traps. Dialogs should manage initial focus, contain focus appropriately, and
  restore focus to the triggering control when closed.
- Communicate control state and validation errors to assistive technologies. Use the shared toast
  system for transient feedback and shared confirmation dialogs for confirmation interactions;
  ensure feedback remains perceivable while dialogs are open.
- Do not rely on color, icons, hover, or visual position alone to communicate meaning. Keep text and
  controls legible in both light and dark themes, including focus, disabled, and error states.
- Support text resizing and zoom without losing content or access to actions. Allow narrow layouts
  to reflow; provide usable scrolling for content that genuinely requires two dimensions.
- Respect reduced-motion preferences and avoid unnecessary animation or flashing content.
- Provide useful alternative text for meaningful images and hide purely decorative images from
  assistive technologies. Give charts a text summary or another way to inspect their information.
- Keep instructions, link text, and errors clear. Preserve accessible names and descriptions across
  supported locales.

## Verification before submitting UI changes

Check the affected workflow, including loading, empty, success, error, and disabled states where
applicable:

1. Complete it using only the keyboard. Check focus visibility, tab order, dialog behavior, and
   focus restoration after closing overlays or completing actions.
2. Inspect names, roles, states, reading order, and announcements with a screen reader when the
   change affects semantics or dynamic feedback. Record the tool and version used.
3. Check light and dark themes, contrast, text resizing, and zoom. Review text at 200% and reflow
   at a narrow viewport or 400% zoom where applicable.
4. Check reduced-motion behavior when changing animations and accessible copy when changing locales.
5. Run `pnpm run build` from `zigfs-admin/web`. Automated accessibility checks may supplement manual
   review; a build or automated scan alone does not establish accessibility.

Include the checks performed, results, and known limitations in the pull request. Do not claim
support for assistive technologies or conformance levels that have not been verified.
