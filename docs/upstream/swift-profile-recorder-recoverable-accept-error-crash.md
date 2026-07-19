# Recoverable Darwin accept error leaves `ProfileRecorderServer` zombie and the next connection traps

Suggested upstream: `apple/swift-profile-recorder` (with a likely companion
issue in `apple/swift-nio`).

Suggested issue title:

> ProfileRecorderServer leaves its listener alive after NIOAsyncChannel accept failure; next connection traps in NIOAsyncWriter.deinit

## Summary

On macOS, a transient `NIOFcntlFailedError` while accepting a connection ends
`ProfileRecorderServer`'s async inbound sequence. SwiftNIO intentionally keeps
the server channel open because this error is recoverable. The profile recorder
catches the sequence error and returns from only the accept task, while the
user-supplied lifetime task keeps running. This leaves a listening server
channel whose `NIOAsyncChannel` source has already been finished.

When the socket accepts the next connection, SwiftNIO transforms the child into
an `NIOAsyncChannel`, cannot deliver it to the finished source, drops it, and
traps in `NIOAsyncWriter.InternalClass.deinit` because the child's outbound
writer was never finished.

This is a two-stage failure:

1. A recoverable accept error permanently ends profile serving but leaves the
   socket listening.
2. The next client connection terminates the host application with `SIGTRAP`.

The first stage was initially mistaken for a listener-only availability bug.
The second connection and crash report establish that it is also a host-process
crash.

## Environment

- macOS 27.0 beta, build `26A5378n`, Apple silicon (`Mac14,5`)
- Swift Profile Recorder `0.3.18`, commit
  `e110ba85da7d43a47b0e964726e84fddcf720192`
- SwiftNIO `2.101.2`, commit
  `cd3e1152083706d77b223fb29110e590efcc70c0`
- Host: LabanApp, an AppKit terminal application
- Transport: HTTP over a Unix-domain socket
- Server lifetime: `withProfileRecordingServer` with a body that remains alive
  until application shutdown

The relevant SwiftNIO code was also inspected at tag `2.101.3` and at the tip
of `main` on 2026-07-19; neither contained a relevant change.

## Observed sequence

The server started successfully at 13:01:54:

```text
sampling profiler listening socketPath=.../laban-samples-61936.sock
```

At 13:02:41 it logged:

```text
error=NIOFcntlFailedError() [ProfileRecorderServer] profile recorder server failure
```

There was no intervening `profile recorder server connection received` log,
which is emitted only after a child async channel reaches the accept loop.

The Unix socket remained present and listening. At 14:06:45, the next `/health`
probe caused the host process to terminate:

```text
Exception Type:     EXC_BREAKPOINT (SIGTRAP)
Termination Reason: Namespace SIGNAL, Code 5, Trace/BPT trap: 5
Triggered by Thread: NIO-SGLTN-1-#1

0  NIOAsyncWriter.InternalClass.deinit + 164
1  NIOAsyncWriter.InternalClass.__deallocating_deinit + 12
2  _swift_release_dealloc + 64
...
12 closure #3 in SelectableEventLoop.runOneLoopTick(selfIdentifier:)
```

The `NIOAsyncWriter` precondition is explicit:

```swift
deinit {
    if !self._finishOnDeinit && !self._storage.isWriterFinished {
        preconditionFailure("Deinited NIOAsyncWriter without calling finish()")
    }
    // ...
}
```

## Reproduction

The initial `fcntl` failure is a documented intermittent Darwin condition, so a
fully deterministic upstream test should inject the error into the server
pipeline. The observed live sequence was:

1. Start a `ProfileRecorderServer` on a Unix-domain socket with
   `withProfileRecordingServer`; keep its body alive independently of the
   accept loop.
2. Cause the server channel's accept path to fire `NIOFcntlFailedError`. On
   Darwin this can occur naturally when NIO applies `F_SETFL(O_NONBLOCK)` or
   `F_SETNOSIGPIPE` to the accepted descriptor.
3. Observe `profile recorder server failure`. Do not stop the lifetime body.
4. Connect another client to the same socket, for example `GET /health`.
5. Observe `SIGTRAP` in `NIOAsyncWriter.InternalClass.deinit`.

A deterministic unit test can fire `NIOFcntlFailedError` through the server
pipeline after bind, assert that the listening channel remains open, then feed
one accepted child. The test should fail if the child async channel is dropped
without its outbound writer being finished.

## Source-level causal chain

All links below are pinned to the affected revisions.

1. On non-Linux platforms, SwiftNIO accepts the descriptor and then calls
   `setNonBlocking`; a failure closes the accepted socket and is rethrown:
   [ServerSocket.swift lines 107-138](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOPosix/ServerSocket.swift#L107-L138).

2. Darwin `EINVAL` from `F_SETFL` is deliberately mapped to the marker error
   `NIOFcntlFailedError`:
   [System.swift lines 1063-1091](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOPosix/System.swift#L1063-L1091).
   The `F_SETNOSIGPIPE` path maps the same condition:
   [SocketProtocols.swift lines 100-123](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOPosix/SocketProtocols.swift#L100-L123).

3. `ServerSocketChannel` intentionally treats `NIOFcntlFailedError` as
   recoverable and does not close the listener:
   [SocketChannel.swift lines 354-405](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOPosix/SocketChannel.swift#L354-L405).

4. `BaseSocketChannel` nevertheless fires every non-EOF read error through the
   pipeline before consulting `shouldCloseOnReadError`; when the error is
   recoverable it continues with the channel open:
   [BaseSocketChannel.swift lines 1190-1232](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOPosix/BaseSocketChannel.swift#L1190-L1232).

5. The async `ServerBootstrap` installs `AcceptBackoffHandler` before the async
   channel handler, configured not to forward handled `IOError`s:
   [Bootstrap.swift lines 721-752](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOPosix/Bootstrap.swift#L721-L752).
   However, `AcceptBackoffHandler` handles only `IOError`; it forwards the
   distinct `NIOFcntlFailedError` unchanged:
   [ChannelHandlers.swift lines 18-95](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOCore/ChannelHandlers.swift#L18-L95).

6. `NIOAsyncChannelHandler.errorCaught` finishes the inbound source with the
   error:
   [AsyncChannelHandler.swift lines 170-174](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOCore/AsyncChannel/AsyncChannelHandler.swift#L170-L174).
   Once that source is nil, later transformed children are removed from the
   buffer rather than delivered:
   [AsyncChannelHandler.swift lines 238-284](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOCore/AsyncChannel/AsyncChannelHandler.swift#L238-L284).

7. `ProfileRecorderServer` catches the thrown async-sequence error, logs it,
   and returns `nil` from the accept task. The sibling body task remains active,
   so the task group and `serverChannel.executeThenClose` do not finish and the
   server channel is not closed:
   [Server.swift lines 399-470](https://github.com/apple/swift-profile-recorder/blob/e110ba85da7d43a47b0e964726e84fddcf720192/Sources/ProfileRecorderServer/Server.swift#L399-L470).

8. A subsequently accepted child is transformed into `NIOAsyncChannel`, then
   discarded because the inbound source was finished. Its outbound writer
   reaches the documented precondition:
   [NIOAsyncWriter.swift lines 159-182](https://github.com/apple/swift-nio/blob/cd3e1152083706d77b223fb29110e590efcc70c0/Sources/NIOCore/AsyncSequences/NIOAsyncWriter.swift#L159-L182).

## Expected behavior

- A recoverable accept error may delay or reject one connection, but profile
  serving should continue.
- If the accept sequence cannot continue, the server channel must close before
  any more child channels can be accepted.
- No client connection should be able to terminate the host application.

## Actual behavior

- One transient Darwin accept error permanently ends the profile server's
  async accept sequence.
- The underlying socket remains open and accepts another connection.
- That connection causes an unfinished async writer to be destroyed, trapping
  the entire host application.

## Suggested fixes

Two defenses are warranted.

1. In SwiftNIO's async server bootstrap, treat `NIOFcntlFailedError` as the
   recoverable accept condition that `ServerSocketChannel` already declares it
   to be. `AcceptBackoffHandler` currently catches only `IOError`, so the marker
   error bypasses its suppression and terminates `NIOAsyncChannel`'s source.
   Handling it before the async channel handler would let the listener continue.

2. In Swift Profile Recorder, make accept-task termination end the whole server
   scope. Do not return `nil` and then wait indefinitely for the user lifetime
   body while the async accept source is dead. Cancel the sibling task and close
   the server channel, or supervise and rebind it. This defense prevents the
   zombie-listener crash even when an unexpected server-pipeline error occurs.

The first change preserves availability; the second guarantees safe failure.
Both should have regression tests covering an injected recoverable accept error
followed by another connection.

## Host-side mitigation

Laban removed the dedicated `ProfileRecorderServer` transport. Its one-shot and
session recording features now call
`ProfileRecorderSampler.sharedInstance.withSymbolizedSamplesInPerfScriptFormat`
directly and share the same demangling helper. The app no longer opens a
profiler socket, so neither failure stage is reachable. A real three-sample
capture regression test verifies that the low-level internal path produces
non-empty perf data.
