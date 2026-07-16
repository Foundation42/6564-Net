; fj_root.asm — the fork-join root: one doorbell, and the LINK chain fans
; the "go" message to every lieutenant. The chain (head in the SQ ring,
; the rest staged in the near page by the loader) fires entry-by-entry on
; transport-ok; the root's work is one instruction plus a halt.
;
; Why a chain of lieutenants and not a chain of 1,000 workers: fan-out
; degree is an architectural constant — a destination costs a PTT slot
; (256 per core) and a chain entry costs 32 near-page bytes (~59 fit in
; scratch). Big fan-out is therefore hierarchical BY CONSTRUCTION on this
; machine, which is how dissemination trees work anyway.

        .org $1000
        SEND 0              ; light the tree
        HLT
