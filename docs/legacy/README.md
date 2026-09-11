# Archived documents

Kept for provenance. Nothing here describes the current system; where a
statement conflicts with the numbered documents in `../`, the numbered
document is right.

| File | What it is | Superseded by |
|------|------------|---------------|
| `ECE3710-README.md` | The README from the ECE 3710 archive the CPU came from, autumn 2025. Its account of the HPS/Linux bring-up is still the best narrative of how that was done, but the technical details are stale — in particular it gives the full-width bridge base `0xC8000000`, and this design uses the **lightweight** bridge at `0xFF200000`. It also ends with "we were unable to get our FPGA to properly read the information sent from the HPS", which is no longer true. | [`../11-board-bringup.md`](../11-board-bringup.md), [`../07-shared-memory-protocol.md`](../07-shared-memory-protocol.md) |
| `ECE3710-course-topics.md` | The team's notes mapping ECE 3710 and CS 3810 lecture topics onto the parts of the project they support. Useful as a record of how the project was scoped against the coursework. | [`../16-project-plan.md`](../16-project-plan.md) |

Also removed in the September 2026 revision: `Documents/PROTOCOL.md`, which
described protocol version 1. It is replaced by
[`../07-shared-memory-protocol.md`](../07-shared-memory-protocol.md), whose
§7.12 tabulates the differences. The old file is in the git history if it
is ever wanted.
