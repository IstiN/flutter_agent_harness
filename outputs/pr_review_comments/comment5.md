🔵 **SUGGESTION (still open from the previous review round): truncated selected rows lose the new accent wrap**

With this change a selected plain label wears the selection accent — but only
on the non-truncated path of `_menuItemRow`. The truncated branch
(`'$prefix${_fitWidth(plain, termWidth - 2)}'`, ~line 106) still renders the
stripped label without the accent, so a long label in a generic picker
reverts to the "invisible selection" behavior this PR fixes. The comment
there ("`plain` carries no `\x1b[0m`, so `_rearmSelection` would be a no-op
here") is also stale after this change. Consider applying the accent wrap
after `_fitWidth` in the truncated branch and updating the comment.
