// House style for the security audit PDF (scripts/build_audit_report.sh).
#set page(
  header: context {
    if counter(page).get().first() > 1 [
      #set text(size: 8pt, fill: luma(110))
      Hollow security review, October 2026 #h(1fr) Internal review
    ]
  },
  footer: context [
    #set text(size: 8pt, fill: luma(110))
    #h(1fr) #counter(page).display("1 / 1", both: true)
  ],
)
#set par(justify: false, leading: 0.62em)
#set table(stroke: 0.4pt + luma(170), inset: 4pt)
#show table: set text(size: 8pt)
#show table: set par(justify: false)
#show table.cell: set align(left)
// A row moves to the next page whole rather than splitting mid-sentence.
#set table.cell(breakable: false)
#show figure.where(kind: table): set block(breakable: true)
// Long paths and identifiers in narrow cells may break after a separator.
#show raw.where(block: false): r => {
  show regex("[/_:.,(]"): c => c + sym.zws
  r
}
#show heading.where(level: 1): it => { if it.outlined { pagebreak(weak: true) }; it }
#show link: set text(fill: rgb("#1f4e8c"))
