# VibeMenu Settings UI research and redesign proposal

**Status:** Option A approved by the product owner on 2026-07-11 and implemented in this worktree.

**Reviewed:** 2026-07-11

## Sources reviewed

Official Apple guidance was the primary source:

- [Human Interface Guidelines — Settings](https://developer.apple.com/design/human-interface-guidelines/settings): minimize the number of settings, choose useful defaults, keep infrequently changed options in Settings, and use the standard macOS Settings scene and title.
- [SwiftUI `Settings`](https://developer.apple.com/documentation/swiftui/settings): use a dedicated Settings scene, `@AppStorage` for persisted preferences, and either a single focused view or panes when the quantity of settings justifies them.
- [SwiftUI `Form`](https://developer.apple.com/documentation/swiftui/form): forms apply platform-appropriate control styling; on macOS the native convention is an aligned vertical form rather than an iOS-style list.
- [SwiftUI `LabeledContent`](https://developer.apple.com/documentation/swiftui/labeledcontent): pair labels and values using framework-managed alignment so custom values line up with pickers and other controls.
- [Human Interface Guidelines — Layout](https://developer.apple.com/design/human-interface-guidelines/layout): put important items first, align components for scanning, group related controls, use consistent spacing, and reveal secondary content progressively.
- [Human Interface Guidelines — Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles): switches carry more visual weight and suit settings that enable substantial behavior; macOS checkboxes suit subordinate choices when indentation and leading-edge alignment make their hierarchy clear. Compact switches can keep grouped-form rows at a consistent height.
- [Human Interface Guidelines — Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls): keep common controls visible, hide advanced details until relevant, label disclosures clearly, and place each disclosure next to the content it reveals.
- [Human Interface Guidelines — Pop-up buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons): use pop-up buttons for small, mutually exclusive sets of choices. This directly fits Claude's usage source.
- [Human Interface Guidelines — Materials](https://developer.apple.com/design/human-interface-guidelines/materials): use materials for semantic separation, not because a blur happens to look attractive; preserve contrast and test across appearance settings.
- [Human Interface Guidelines — Labels](https://developer.apple.com/design/human-interface-guidelines/labels): use system fonts and system label colors to express hierarchy; reserve secondary label color for supplemental text.
- [WWDC24 — Tailor macOS windows with SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10148/): tailor a window to its focused purpose and use window material only when it supports the content, rather than treating it as decoration.

Two established macOS examples were reviewed for pattern comparison, not copying:

- [Sindre Sorhus's Settings package](https://github.com/sindresorhus/Settings): demonstrates the classic toolbar-pane model and grid-like label/control alignment. It reinforces that panes are useful when there are truly separate categories, but would be unnecessary navigation for VibeMenu's small set of controls. No dependency from this project is proposed.
- [SwiftBar](https://github.com/swiftbar/SwiftBar): a mature menu-bar utility that keeps specialist and developer preferences out of its primary UI. The applicable lesson is scope discipline: expose the common controls, and progressively disclose specialist setup.

## Key UI principles learned

1. **Settings should be a decision surface, not documentation.** Put the few choices people may change in the window. Keep explanations to short status or consequence text; the detailed privacy contract belongs in the existing documentation and confirmation sheet.
2. **Use one alignment system.** Labels need a stable leading column and values need a stable trailing/value column. Status belongs with the value it describes, not centered on a separate line.
3. **Match control weight to impact.** Launch at login, session tracking, and whole usage sections justify switches. Individual usage-window visibility is subordinate customization and should not receive equally large switches or a free-floating checkbox stack.
4. **Show details only when actionable.** Provider controls can expand, usage-dependent values should appear only when usage is enabled, and row customization should appear only when detected rows exist.
5. **Prefer native semantics over custom decoration.** Standard switches, pop-up buttons, menus, disclosure indicators, system fonts, system colors, separators, and focus behavior provide more polish than bespoke glass or chip drawing.
6. **Material cannot rescue weak structure.** Establish hierarchy with grouping, alignment, spacing, and typography first. A system window background or subtle system control background is enough; nested blur layers are not.
7. **Keep parallel providers structurally parallel.** Claude and Codex should share the same order — provider header, primary controls, source/status, rows — with only the genuinely provider-specific controls in Claude Advanced.

## What applies to VibeMenu

- A single Settings window is preferable to tabs. There are only three global display/lifecycle choices and two related providers.
- The current preference model already supports the intended hierarchy. The redesign can preserve all existing keys and bindings.
- The existing off-main-thread detection refreshes should remain intact. Only their compact presentation changes.
- The existing setup confirmation is the correct place for the detailed Claude Code capture consequence. The Settings body only needs a compact action and status.
- The existing privacy and architecture documents remain the place for long explanations. Settings should use concise, truthful labels without weakening the privacy contract.
- The global `showClaudeStatus` key can retain its backward-compatible name while the visible label becomes **Show session rows**.
- The existing `claudeLimitsSectionExpanded` and `codexLimitsSectionExpanded` keys can store the two provider disclosure states; no new persisted preference is needed.

## What should be avoided

- Large inset cards with generous internal padding around only a few controls.
- A narrow window that forces secondary copy to wrap and makes the form feel taller.
- Centered status, freshness, or group labels.
- Bare checkbox stacks whose indentation does not visibly connect them to a parent setting.
- Multiple paragraphs about local files, privacy, and experimental behavior inside the primary Settings flow.
- A fake picker for Codex's fixed source.
- Provider-specific wording that makes Claude and Codex appear to follow unrelated models.
- Custom glass, gradients, shadows, icons, or assets that do not communicate state.
- A permanent empty “Rows” area while data is unavailable.
- Stale terminology such as **AI Agent**, **Codex display-only**, or a claim that Codex sessions can never prevent sleep.

## Screenshot diagnosis

The attached screenshot confirms the reported problems:

- At roughly 358 points wide, the window is too narrow for a label/value settings layout, yet its expanded contents make it roughly 677 points tall. The proportions feel like a long mobile form rather than a compact Mac utility.
- The three large rounded surfaces dominate the hierarchy. Their generous outer margins, internal padding, and corner radii make every group feel equally important and consume height without adding clarity.
- The top toggles are understandable, but their large switch controls and row heights overstate simple preferences. The explanatory footer makes the global group read as a card with documentation attached.
- Claude and Codex are permanently expanded in the screenshot, so the first scan exposes every implementation detail instead of the provider-level choices.
- “Show rows” is centered independently from both the left label column and the checkbox column. It looks like a caption over an accidental stack rather than a setting.
- The usage checkboxes begin near the center of the window and shift slightly with label width. They neither align with the provider controls nor form a clear indented hierarchy. The disabled row adds visual weight even though it is subordinate customization.
- Claude's source value is trailing-aligned, but its detected source/freshness becomes a centered line below. Codex repeats the same information with a fixed source on one line and `live` centered on another. This breaks the eye's scan path.
- **Advanced** sits after a large body with no strong relationship to the controls it contains, so it feels appended rather than intentionally progressive.
- The Codex tracking explanation wraps across two lines and competes with the primary controls. Its meaning is important, but the full sentence does not need to be permanently visible.
- Provider headers, row labels, checkbox labels, and status text have insufficiently distinct typography. Boldness and size do not establish a reliable primary/secondary rhythm.
- The repeated large cards plus uniform dark fill flatten depth. The window background and card backgrounds are different, but the difference does not explain hierarchy.
- The current source still contains stale UI copy — **Show AI Agent sessions** and the obsolete claim that Codex is display-only and never keeps the Mac awake — which must not survive the redesign.

## Problem

VibeMenu exposes the correct behavior, but the Settings UI presents it as three oversized implementation panels. Weak alignment, excessive vertical space, repeated explanation, and raw per-row checkboxes obscure the few decisions a user actually needs to make. The result is difficult to scan and visually inconsistent with a focused native macOS menu-bar utility.

## Constraints

- Work is limited to the Settings UI, supporting Settings-only view structure, this design document, and the development log.
- Preserve `CLAUDE.md` and every existing preference key unless a demonstrated blocker requires approval for a change.
- Preserve launch-at-login, thermal visibility, global session-row visibility, Claude/Codex usage visibility, Claude source selection, hidden-row persistence, Claude Code capture setup/removal, and Codex tracking behavior.
- Do not change parsers, readers, data sources, privacy boundaries, power policy, or Claude/Codex sleep-prevention logic.
- Do not read `logs_2.sqlite`.
- Use public SwiftUI/AppKit APIs available on macOS 15 or earlier; no private API, entitlement, root access, or new dependency.
- Keep the window short, usable in light/dark and accessibility contrast modes, and honest when no usage rows are detected.
- Do not touch another worktree or wrapper repository, commit, push, or rewrite history.

## Options

### Option A — Compact aligned form with provider disclosures

Use one focused window with a compact global group followed by parallel Claude and Codex disclosure groups. Inside expanded providers, use an aligned label/value grid. Use native switches for primary booleans, a pop-up picker for Claude source, a fixed text value for Codex source, and a compact Rows menu containing checkmarked row choices.

**Tradeoffs:** Best scanning, smallest height, and least custom styling. A Rows menu adds one click compared with visible checkboxes, but removes the largest source of visual clutter and scales cleanly if Claude exposes additional windows.

### Option B — Compact inset groups with visible subordinate checkboxes

Keep provider cards, reduce their padding/radius, and place row checkboxes in a properly labeled, leading-aligned inset list below the source row.

**Tradeoffs:** All row choices remain visible and the hierarchy is clearer than today. The window is still taller, dynamic row counts can destabilize its size, and checkbox-heavy providers continue to feel more like configuration panels than a small utility.

### Option C — General / Providers panes

Use classic toolbar panes: General for launch/display, Providers for Claude/Codex.

**Tradeoffs:** Strong macOS precedent and room for future growth. It adds navigation for fewer than a dozen settings, separates global session visibility from its providers, and encourages future settings growth. It is disproportionate for the requested short window.

## Recommendation

Implement **Option A**.

### Proposed structure

```text
VibeMenu Settings

General
  Launch at login                                  [switch]
  Thermal status                                  [switch]
  Show session rows                               [switch]

▾ Claude
  Show usage                                      [switch]
  Source                                     [Automatic ▾]
                                             Desktop · Live
  Rows                                     [3 of 3 shown ▾]  ← only with detected rows
  ▸ Advanced

▾ Codex
  Track Codex sessions                            [switch]
  Show usage                                      [switch]
  Source                                      Codex Desktop
                                                      Live
  Rows                                     [2 of 2 shown ▾]  ← only with detected rows
```

When **Show usage** is off, that provider hides Source, freshness, and Rows. Claude Advanced remains available because Desktop session titles are independent of usage; capture setup is shown there only when relevant to the selected usage source.

Claude Advanced contains:

- **Use Claude Desktop session titles** — existing switch and preference.
- **Claude Code capture** — compact status plus **Set Up…** or **Remove** action, retaining the existing confirmation/error behavior.

### Visual hierarchy

- Window title: system Settings title, no custom hero/header.
- Group/provider headings: system headline/semibold treatment, one level above row labels.
- Row labels: system body/callout, leading aligned.
- Values and controls: trailing/value-column aligned.
- Freshness and capture status: one short secondary/caption line directly below the related value, never centered across the card.
- Errors: red caption directly below the failed action only.
- No always-visible privacy paragraph. Existing docs and the capture confirmation provide the detail without weakening disclosure.

### Row visibility treatment

Use a small **Rows** value row whose control reads, for example, **2 of 3 shown**. Activating it opens a native menu with one checkmarked toggle item per detected row. The menu items retain the existing stable visibility IDs and write the same newline-encoded hidden-ID preferences.

This treatment is recommended because it:

- keeps every row aligned with Source instead of floating in the middle;
- presents row visibility as customization, not equal-weight primary behavior;
- supports two, three, or more rows without increasing window height;
- uses native keyboard, focus, checkmark, and menu behavior;
- disappears entirely when usage is off or there are no detected rows;
- never creates an empty placeholder area.

If manual QA shows SwiftUI's menu toggle rendering is unclear on macOS 15, the fallback is Option B's leading-aligned small checkbox inset, not custom chips.

### Spacing and alignment rules

- Target window width: approximately **440 points** so labels and values fit without wrapping.
- Outer content inset: **20 points horizontal**, **16–18 points vertical**.
- Gap between global/provider groups: **12 points**.
- Group internal inset: approximately **12 points vertical / 14 points horizontal**.
- Standard row minimum height: **28 points**; use compact/small native control sizes.
- Row-to-row gap: **8 points**; status text sits **2–4 points** below its owning value.
- Label/value grid gap: **16 points** with one stable label column across each provider.
- Disclosure content aligns with provider body content; nested Advanced content gets one clear indentation level only.
- Separators, when useful, start at the row-label leading edge and do not span arbitrary nested margins.
- All numbers are implementation targets to validate visually, not a reason to fight native control metrics.

### Surface and material treatment

Use the normal Settings window background and system semantic colors. Provider grouping may use a restrained `controlBackgroundColor`-style surface and a subtle separator/border, but no nested blur. Do not add Liquid Glass-only APIs because the deployment baseline is macOS 15. Standard SwiftUI controls, colors, materials, and `Settings` are public, require no entitlement or root access, and are sandbox-compatible; appearance can vary by OS and accessibility settings, so manual testing is required.

### Implementation plan

1. Keep the existing models, `@AppStorage` keys, detection functions, and setup alert unchanged.
2. Replace the monolithic grouped `Form` body with compact Settings-only layout helpers in `VibeMenuApp.swift`, avoiding an Xcode project-file change unless extraction clearly improves maintainability.
3. Add small private reusable views for a group surface, provider disclosure/header, aligned settings row, secondary status, and Rows menu. Keep them presentation-only.
4. Bind Claude and Codex provider disclosures to the existing expansion keys. Add the currently missing `@AppStorage` binding for `codexLimitsSectionExpanded`; do not add a new key.
5. Replace stale visible wording with the approved short labels: **Show session rows**, **Claude**, **Codex**, **Track Codex sessions**, **Show usage**, **Source**, **Rows**, **Advanced**.
6. Show usage-dependent source/status/row controls only while usage is enabled. Show Rows only when the detected list is nonempty.
7. Move Desktop titles and capture setup/removal into Claude Advanced; remove the two privacy-detail disclosures and long in-window paragraphs.
8. Preserve the existing confirmation preview, install/remove calls, refresh triggers, status/error presentation, and off-main-thread filesystem work.
9. Append the required implementation entry to `docs/DEVELOPMENT_LOG.md` with real command results and what was or was not manually verified.
10. Run the complete requested verification suite and inspect the final diff for any parser, privacy, data-source, or power-policy changes.

## Risks

- **SwiftUI size behavior:** disclosure expansion can cause Settings windows to retain an awkward prior size. Mitigation: use content-driven sizing where it remains stable, set a practical width, and cap/scroll only if expanded content exceeds a reasonable screen height.
- **Menu toggle appearance on macOS 15:** checkmarked `Toggle` items inside a SwiftUI `Menu` need visual confirmation on the minimum OS. Mitigation: fall back to a small leading-aligned checkbox inset if native menu semantics are unclear.
- **Dynamic source status length:** stale ages and capture errors can be longer than `Live`. Mitigation: keep normal status one line and let actual errors wrap locally without widening the entire layout.
- **Conditional control movement:** turning usage on reveals additional rows. This is intentional progressive disclosure, but must not leave dead space or move unrelated global controls.
- **Existing stale comments/docs:** source comments still describe Codex as display-only. The UI task should remove stale wording in touched Settings code, while avoiding an unrelated documentation rewrite.
- **Visual verification:** compilation cannot establish polish. A manual light/dark smoke test of the built app remains required.

## Testing plan

Automated/build verification required after implementation:

```sh
swift build
scripts/test.sh
xcodebuild -project App/VibeMenu.xcodeproj -scheme VibeMenu -configuration Debug -derivedDataPath ./.derivedData build
git restore .derivedData 2>/dev/null || true
git status --short
git diff --stat
git diff --check
test -f CLAUDE.md
git grep -n "AI Agent:" -- Sources Tests docs README.md || true
git grep -n "display-only\|never keeps\|never keep" -- Sources Tests docs README.md || true
git grep -n "logs_2.sqlite\|feedback_log_body" -- Sources Tests docs README.md || true
```

Manual smoke-test checklist:

- Open Settings from the menu and with Command–Comma; confirm the title and compact initial height.
- Check light mode, dark mode, Increase Contrast, and Reduce Transparency.
- Confirm every label/value column aligns and no text truncates at normal system text size.
- Toggle Launch at login and confirm the UI reflects the actual system status after reopening.
- Toggle Thermal status and Show session rows; confirm their menu visibility behavior is unchanged.
- Collapse and expand Claude/Codex, close/reopen Settings, and confirm the existing expansion preferences persist.
- Enable/disable Claude usage; verify Source/status/Rows appear only when applicable.
- Exercise Automatic, Claude Desktop, and Claude Code sources; confirm the picker and freshness text update.
- Test Claude with zero, two, and three detected usage rows; confirm no empty Rows area and correct shown-count text.
- Hide/show each Claude usage row; reopen Settings and confirm hidden-ID persistence and menu output.
- Toggle Desktop session titles and confirm the preference remains independent of usage.
- Open Claude Advanced; test capture preview/cancel, setup, status refresh, removal, and error wrapping.
- Enable/disable Codex tracking; verify tracking and its existing sleep-prevention input remain unchanged.
- Enable/disable Codex usage; confirm fixed **Codex Desktop** source, subtle freshness, and conditional Rows menu.
- Hide/show Codex limit rows and confirm the separate Codex hidden-ID preference remains intact.
- Confirm both providers can be expanded without oversized cards, centered text, empty gaps, or a window that exceeds a practical screen height.
- Confirm no privacy paragraph dominates the primary flow and no stale **AI Agent** or **display-only** claim appears.

## Product approval

The product owner approved **Option A — Compact aligned form with provider disclosures** on
2026-07-11, including the compact Rows menu and Claude Advanced placement described above.
