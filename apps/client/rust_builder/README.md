# PiRC Rust bridge build integration

This private Flutter FFI plugin builds `../rust` with Cargokit for the native client targets. Shared business logic lives in `packages/core`; generated Dart bindings live in `apps/client/lib/src/rust`.

`cargokit/` is vendored build tooling and retains its upstream license.
