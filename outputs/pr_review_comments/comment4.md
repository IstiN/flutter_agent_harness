🔵 **SUGGESTION (still open from the previous review round): 3:1 label floor is only checked on `toolErrorBg`, not `toolSuccessBg`**

`tuiToolRow` paints the label in `toolTitle` over BOTH tints — done rows use
`toolSuccessBg`, failed rows `toolErrorBg` — but this matrix only asserts
`toolTitle` on `toolErrorBg`. A future palette whose `toolTitle` clears 3:1 on
the error tint but not the success tint would slip through the floor
enforcement unnoticed. Extend the pair list to cover both tints, mirroring
the per-tint glyph-rail checks below.
