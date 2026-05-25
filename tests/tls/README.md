Xymon TLS — test rig
=====================

Local helpers for the native-TLS prototype (`docs/tls/00-DESIGN.md`).

`gen-certs.sh`
--------------

Generates a self-signed CA + server cert + client cert under `out/` so you
can run xymond with mTLS locally without setting up a real PKI. Idempotent;
pass `--force` to regenerate from scratch.

```
$ ./tests/tls/gen-certs.sh
```

Outputs:

| File                | Purpose                                        |
|---------------------|------------------------------------------------|
| `out/ca.crt`        | CA cert — both sides verify against this       |
| `out/ca.key`        | CA private key — keep for issuing more certs   |
| `out/server.crt`    | Server cert, CN=xymon-test-server, SAN=localhost,127.0.0.1 |
| `out/server.key`    | Server private key                             |
| `out/client.crt`    | Client cert, CN=xymon-test-client              |
| `out/client.key`    | Client private key                             |

The `out/` directory is `.gitignore`d. Don't commit private keys.


`test-handshake.sh` — automated smoke test
------------------------------------------

Once the server is built (`./configure --server && make`):

```
$ ./tests/tls/test-handshake.sh
```

Boots xymond on `127.0.0.1:1985` with the test certs, drives an mTLS
handshake via `openssl s_client`, verifies the server logged the expected
peer CN, and (if the `xymon` client binary is also built) sends a real
status message via `xymons://`. Exit code 0 means everything wired up
correctly.

Override with environment variables if your binaries live elsewhere:

```
$ XYMOND_BIN=/path/to/xymond XYMON_BIN=/path/to/xymon ./tests/tls/test-handshake.sh
```


Manual smoke test (terminal A + terminal B)
-------------------------------------------

Terminal A (server):
```
xymond ... \
  --tls-listen=127.0.0.1:1985 \
  --tls-cert=$PWD/tests/tls/out/server.crt \
  --tls-key=$PWD/tests/tls/out/server.key \
  --tls-ca=$PWD/tests/tls/out/ca.crt
```

Terminal B (client):
```
XYMSRV=xymons://localhost:1985 \
XYMON_TLS_CA=$PWD/tests/tls/out/ca.crt \
XYMON_TLS_CERT=$PWD/tests/tls/out/client.crt \
XYMON_TLS_KEY=$PWD/tests/tls/out/client.key \
xymon localhost 'status testpage.test green hello over TLS'
```

The server log should record the client's CN (`xymon-test-client`) and the
status message should appear in xymond's normal pipeline.
