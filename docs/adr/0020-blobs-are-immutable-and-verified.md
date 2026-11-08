# ADR-0020 — Module blobs are immutable and verified on every read.

*Context:* Deployed source lives on disk and is re-read whenever a cell is opened; a torn or truncated file would be executed as code. *Decision:* Content-addressed storage under `blobs/<sha256>.bin`, written to a unique temporary name, fsynced, then renamed into place, with the containing directory fsynced too. Reads re-hash and reject a mismatch, a short read, or a zero-length file whose name is not the hash of empty. *Consequences:* Deploys are idempotent (identical bytes are one file); corruption is detected at load and surfaces as `ModuleUnavailable` rather than executing different code; GC may only delete a blob that no cell, deployment row or `meta.json` pin refers to.

_Status: accepted. Immutable; supersede rather than edit._
