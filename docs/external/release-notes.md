# Release Notes

## July 2, 2026

- **Fix — Cloud stall backstop now fails closed on an unreadable workpad status** — The stall backstop that watches cloud `/devflow:implement` runs could previously misread a corrupted or unrecognized workpad status as a healthy in-progress run, silently spending one of its limited automatic resume attempts instead of flagging the problem. It now recognizes that condition as unreadable and fails the run loud with a diagnostic comment, the same way it already handled a missing status, so automatic resume attempts are no longer wasted on runs it cannot actually read. (#283)
