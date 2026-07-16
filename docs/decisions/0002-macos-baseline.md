# 0002 — macOS baseline: macOS 15+, Apple Silicon first

- **Status:** Accepted
- **Date:** 2026-07-02
- **Deciders:** Kirill Chistov (product owner).

## Context

VibeMenu is a native menu-bar utility that will lean on modern SwiftUI (`MenuBarExtra`),
Swift 6 strict concurrency, and public power/thermal APIs. Supporting older macOS
versions widens the testing matrix and constrains which APIs and SwiftUI affordances are
available. The target audience — developers running local AI coding agents on recent
Apple Silicon MacBooks — skews toward current hardware and OS versions.

## Decision

- **Deployment target: macOS 15+.** The Swift package sets `platforms: [.macOS(.v15)]`.
- **Apple Silicon first.** Development, testing, and the first releases target
  Apple Silicon. Intel is not a priority and is not tested.

## Consequences

- Free use of `MenuBarExtra`, modern SwiftUI, and current public system APIs without
  back-compat shims.
- A smaller test matrix (one recent OS line, one architecture family) that fits the
  lightweight, low-overhead ethos.
- Users on older macOS or Intel Macs are not supported initially. This can be revisited
  with evidence of demand, via a new ADR.
- This was verified to build on the current toolchain: `.macOS(.v15)` compiles and links
  with the Swift 6.3 Command Line Tools toolchain used for bootstrap.

## Alternatives considered

- **macOS 13/14 baseline for wider reach.** Rejected for now: adds back-compat cost for a
  pre-alpha tool whose audience is on recent hardware.
- **Universal (Intel + Apple Silicon) from day one.** Rejected: doubles the surface with
  little benefit for the target user; Apple Silicon is where agent-heavy dev happens.
