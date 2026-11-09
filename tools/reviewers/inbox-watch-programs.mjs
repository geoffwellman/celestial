// Every `_INBOX_WATCH_JQ` program (lib/inbox.sh) a release has started an
// inbox watcher with, as the sha256 of its exact text (the jq argv element).
// A watcher keeps running the program it was started with after its checkout
// is updated, so retire.mjs recognises its jq child by this list as well as
// by the launch checkout's current text. Anything else is an unknown child.
//
// Changing _INBOX_WATCH_JQ: ADD the new program's hash here, with the release
// it came from (retire.test.mjs fails until you do). Never remove an entry
// while a watcher started on that release may still be running.
export const INBOX_WATCH_PROGRAMS = new Set([
  // v0.4.0 (#136) through v0.5.0, and main until #285.
  '2fd6c5132bc28d767b9967af54030e9b668127e961a4bd9f2c8f64af0f2859c7',
  // main since #285 (unreleased): adds the route's people ("r:" field).
  '12aaae3c2d3fe3468adcab4844b69d8a2145abd8c7302ee53c39f11c56198c3a',
]);
