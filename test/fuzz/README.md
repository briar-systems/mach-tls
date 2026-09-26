# the fuzz lane

`corpus/<boundary>/` holds the retained inputs for every untrusted-input entry
point of the library. Each directory pairs with a row of the registry in
`src/boundaries.mach`, which names the harness that answers it:

| boundary | entry point |
|---|---|
| `record` | `record.inspect`, both versions, protected and not |
| `alert` | `record.decode_alert`, both versions |
| `frame` | `handshake.parse_version`, both framings |
| `extensions` | `extensions.next` and `extensions.validate` in every context |
| `client-hello`, `server-hello`, `encrypted-extensions`, `certificate-request`, `certificate`, `certificate-verify`, `finished`, `new-session-ticket`, `key-update` | the TLS 1.3 parsers in `handshake.codec` |
| `tls12-client-hello`, `tls12-server-hello`, `tls12-certificate`, `tls12-server-key-exchange`, `tls12-certificate-request`, `tls12-server-hello-done`, `tls12-client-key-exchange`, `tls12-certificate-verify`, `tls12-finished` | the TLS 1.2 parsers in `tls12.messages` |
| `x509` | `cert.x509.parse` |

A message boundary's input is the message body. The harness frames it with its
type and exact length, which is what the framer hands a parser.

## Answers

An input is answered when its entry point parses it or refuses it with a typed
error, and every view the parse publishes lies inside the input. A harness
also checks what its parser promises: an accepted hello is structurally exact,
an accepted key-exchange point matches its curve, a list that validates walks
to its end, a certificate chain walks to the count it reported, and a framer
never asks for bytes it already holds. Breaking any of these is a finding.

Each input is copied so that it ends on the last byte before an unreadable page
(`std.allocator.testing`), so a parser that reads one byte past its input
faults on the spot. A crash is a finding. So is a hang: every walk a harness
drives is bounded by its input's length, and the replay runs under a timeout.

## Running it

From the repository root:

```sh
mach dep pull test/fuzz
mach build test/fuzz
test/fuzz/out/linux-x86_64/debug/bin/fuzz replay
test/fuzz/out/linux-x86_64/debug/bin/fuzz one <boundary> <file>
test/fuzz/out/linux-x86_64/debug/bin/fuzz mutate <boundary|all> <runs> <seed> [--retain]
```

`replay` answers every retained input and fails on a finding, on an empty
boundary directory, or on a directory no boundary answers. CI replays it in both
profiles on the heavy tier: a pull request into `main`, or a dispatch with
`heavy: fuzz` or `heavy: all`. `mach build test/fuzz` runs on every pull request
so the lane cannot rot.

`mutate` is the on-demand search. It draws from a boundary's corpus, applies one
to three structural mutations (flip a bit, set a byte, truncate, extend, swap,
zero a run) from one seeded generator, and answers the result, so a seed and a
run count replay exactly. A finding is written to
`test/fuzz/out/findings/<boundary>/`. With `--retain`, an input whose outcome
the corpus does not hold yet is minimized, by cutting ever smaller chunks while
the outcome holds, and written to its boundary's directory as `m-<outcome>.bin`.

An outcome is what the parse answered: its status or error, and for an
accepted input the shape it took (the algorithms it names, the certificate
extensions present, how many list entries, bucketed). This is not code
coverage. There is no coverage instrumentation for Mach, so two inputs that
reach different code with the same answer count as one.

## The corpus

The named files are valid seeds, each accepted by its parser: the valid inputs
the unit suite's former mutation corpora started from, a seed for each parser
they did not reach, and the interop fixtures' certificates in DER. The `m-*`
files were retained by `fuzz mutate all 20000 1 --retain`.

To retain a new input by hand, put the file in its boundary's directory. When a
finding is fixed, retain the input that found it, so the replay keeps it fixed.
