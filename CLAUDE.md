# Agent Tracker

Keep track of your agent sessions in your MacBook's Menu Bar.

## Project overview

A macOS menu bar app showing the status of running AI agent sessions (active /
idle / waiting for input), with a dropdown session list and notifications.

## Current state

Freshly initialized — no functional code yet. Only repo fundamentals (README,
license, gitignore) exist.

## Planned stack

- Swift + SwiftUI, using `MenuBarExtra` for the menu bar presence
- Native macOS app (no Electron), targeting recent macOS versions

## Conventions

- Keep the app lightweight: it lives in the menu bar, so minimal footprint and
  no unnecessary dependencies.
