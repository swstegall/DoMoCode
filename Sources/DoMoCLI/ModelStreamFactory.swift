// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one place a resolved model becomes the closures the harness runs on.
//
// Three surfaces drive an `AgentHarness` — print mode (`-p`), the inline REPL,
// and the embedded server behind the full-screen client — and each used to spell
// its own `streamCompletion` call. Three spellings meant three chances to forget
// an argument, and they had already diverged: `-p` forwarded `onResponse` (so it
// could warn when a LiteLLM fallback answered with a different model), the REPL
// passed `{ _ in }`, and the server passed nothing at all. The README states
// flatly that the UI must say when a fallback fired "rather than lie", so that
// divergence was a documented promise kept on exactly one of three surfaces.
// Per-alias `rates` — the primary source of cost in this port — had the same
// shape of problem waiting: a call site that omits it produces a session whose
// every cost is zero, silently.
//
// So the call is written once here and adopted everywhere. A new argument is
// added in one place and every surface gets it.

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM

// MARK: - Turn stream

/// The ``AgentStreamFn`` for one model: a single LLM call per turn, carrying the
/// alias's reasoning effort and cost rates, and reporting the response head.
///
/// `onResponse` fires once per request, off the caller's task, with the initial
/// header block — the only place ``ResponseMetadata/attemptedFallbacks`` is
/// visible, and therefore the only place a surface can learn that a different
/// model answered. Surfaces that pass `nil` simply say nothing; there is no
/// second channel that would have told them.
///
/// `rates` comes off the runtime rather than the client because pricing is
/// per-alias: one `LiteLLMClient` serves the main model and the (possibly
/// cheaper) summarization model in the same process, and a client-wide rate table
/// would bill both at whichever one was configured.
func makeStreamFn(
    client: LiteLLMClient,
    runtime: ModelRuntime,
    onResponse: (@Sendable (ResponseMetadata) -> Void)? = nil
) -> AgentStreamFn {
    { context in
        client.streamCompletion(
            model: runtime.model,
            context: context,
            reasoningEffort: runtime.reasoningEffort,
            rates: runtime.rates,
            onResponse: onResponse
        )
    }
}

// MARK: - Summarization

/// A ``Summarizer`` that runs one compaction request against `model`.
///
/// The prompts are ``CompactionPrompts/system`` and
/// ``CompactionPrompts/instruction``, referenced rather than copied: the harness's
/// built-in fallback summarizer sends the same two strings, so a session compacted
/// by the CLI and one compacted by the harness produce comparably-shaped summaries
/// instead of drifting into two vocabularies.
///
/// It deliberately does **not** prepend ``CompactionPrompts/priorSummaryPreamble(_:)``.
/// ``compact(_:id:parentId:timestamp:usage:summarize:)`` already inserts that
/// message at the head of what it hands a summarizer, so doing it here would send
/// the standing summary twice and pay for it twice.
///
/// The terminal assistant message's ``Usage`` rides back on the result. That is
/// the only route by which a summarization call's cost ever reaches a session
/// total — ``Compaction/usage`` is filled from exactly this value — so dropping it
/// makes every compacting session look cheaper than it was.
///
/// - Parameters:
///   - model: the alias to send on the wire. Passed separately from `runtime`
///     because the caller resolves the two independently (a `compaction.model`
///     override names the alias; the runtime carries whatever knobs that alias was
///     configured with), and this argument is the one that decides the request.
///   - runtime: the reasoning effort and cost rates to bill the call at.
func makeSummarizer(client: LiteLLMClient, model: String, runtime: ModelRuntime) -> Summarizer {
    { messages in
        let request = Context(
            systemPrompt: CompactionPrompts.system,
            messages: messages + [.user(CompactionPrompts.instruction)],
            tools: []
        )
        var terminal: AssistantMessage?
        for try await event in client.streamCompletion(
            model: model,
            context: request,
            reasoningEffort: runtime.reasoningEffort,
            rates: runtime.rates
        ) {
            if let message = event.terminalMessage { terminal = message }
        }
        guard let terminal else {
            throw DoMoError(.provider(status: nil, isRetryable: false), "Summarization produced no response")
        }
        // A failed turn must not become a summary. Compaction that could not
        // summarize writes no entry, which leaves the context unbounded but
        // intact; a truncated or empty "summary" would silently delete the
        // conversation it was supposed to preserve.
        if let failure = terminal.failure { throw failure }
        return SummarizerResult(text: terminal.text, usage: terminal.usage)
    }
}

// WHETHER a session gets one of these is decided a layer up, by whoever resolved
// the configuration: `DoMoCodeCommand.compactionSummarizer` builds one only for a
// small model that genuinely differs from the session's own, because `smallModel`
// defaults to `model` and installing a summarizer for everybody would change a
// compaction path nobody asked to change. `PrintMode` and `InteractiveMode.make`
// take the result as an injected `Summarizer?` and hand it to the harness
// unexamined, so the rule has exactly one implementation.
