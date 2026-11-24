# R3-B reproduction evidence: the sidebar tab model, read from outside the
# binary with AT-SPI over D-Bus (verification law rule 1, mechanism pin).
#
# Cell: scripts/check-sidebar-model.sh <repo-root> [work-dir]
#   BRACKET  sidebar off (window-show-tab-bar = always): the title bar's tab
#            list IS visible to a11y. Proves the instrument is not blind.
#   WINDOWS  exactly one realized window (role frame)
#   TABS     the sidebar's list carries rows
#   SURFACE  a scroll pane and a focusable terminal panel exist
#
# Measured 2026-11-04, this host, a11y-ON environment, two runs per binary:
#
#   v0.1.0 (provenance 0.1.0-main+ghostty.1.4.0.ec30fe4)
#     BRACKET ok (2 title-bar tab lists)   WINDOWS ok   TABS ok (2 rows, 1 list)   SURFACE ok
#     RESULT: pass
#
#   tip 7b7709e88
#     BRACKET ok (2 title-bar tab lists)   WINDOWS ok   TABS FAIL (0 rows, 0 lists)   SURFACE ok
#     RESULT: fail (TABS)
#
#   pre-fix 1098d5f40 (the round-3 bundle source, provenance 0.1.0-HEAD+1098d5f40)
#     TABS FAIL (0 rows) - the same reading, so the defect shipped in the
#     round-3 bundle and is not caused by any commit after it.
#
# Reading the tree: v0.1.0's sidebar is `scroll pane -> list(2) -> row header`;
# the tip has no list node at all, while its terminal and title bar are intact.
#
# Tree-level instrumentation (removed before this commit) showed the tab view
# carrying its page and the sidebar model holding it (rebuildSortModel pages=1,
# model=1 sort_items=1) with nothing rendered - the model is populated and the
# list is not, which is a layout/realisation defect above the model layer.
#
# Licence: AGPLv3 (njuggle).
