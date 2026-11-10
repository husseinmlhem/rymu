"""Exercise the compiled Windows DLL without starting a host or storing credentials."""
from __future__ import annotations

import base64
import ctypes
import json
import os
import sys
import tempfile
from pathlib import Path


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def main() -> None:
    if sys.platform != "win32" or len(sys.argv) != 2:
        raise SystemExit("Run this on Windows with the freshly compiled librustdesk.dll path.")
    dll = Path(sys.argv[1]).resolve(strict=True)
    with os.add_dll_directory(str(dll.parent)):
        engine = ctypes.WinDLL(str(dll))
        call = engine.rymu_control
        call.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        call.restype = ctypes.c_ssize_t

        def request(op: str, **values: object) -> dict:
            raw = json.dumps(dict(op=op, **values)).encode()
            data = ctypes.create_string_buffer(raw)
            output = ctypes.create_string_buffer(65536)
            written = call(data, len(raw), output, len(output))
            assert 0 < written <= len(output)
            return json.loads(output.raw[:written])

        # RFC 8032 section 7.1, public test vector; this seed is not used as an application key.
        seed = b64(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        pub = b64(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
        assert request("devicePublicKey", signingSeed=seed)["value"] == pub
        print("PASS compiled Ed25519 public-key operation against RFC 8032 vector")
        assert "error" in request("devicePublicKey", signingSeed="bad")
        assert "error" in request("signEnrollment", signingSeed=seed, proof="not enrollment")
        print("PASS rejects invalid key and cross-protocol signing request")
        assert "error" in request("configureTransport", rendezvousServer="rs.rustdesk.com",
            relayServer="127.0.0.1:21117", rendezvousKey=pub)
        print("PASS public default rendezvous is rejected")
        assert request("hostOnline")["value"] is False
        print("PASS hosting is inactive in the fresh process")
        old_appdata = os.environ.get("LOCALAPPDATA")
        with tempfile.TemporaryDirectory(prefix="rymu-bridge-vault-") as scratch:
            os.environ["LOCALAPPDATA"] = scratch
            try:
                fixture = {"fixture": "Rymu DPAPI test sentinel"}
                assert request("vaultRead")["value"] is None
                assert request("vaultWrite", data=fixture)["value"] is True
                sealed = Path(scratch, "Rymu", "Control", "account.dat")
                assert fixture["fixture"].encode() not in sealed.read_bytes()
                assert request("vaultRead")["value"] == fixture
                assert request("vaultClear")["value"] is True
                assert not sealed.exists() and request("vaultRead")["value"] is None
                print("PASS isolated Windows DPAPI write, encrypted storage, read and clear")
            finally:
                if old_appdata is None:
                    os.environ.pop("LOCALAPPDATA", None)
                else:
                    os.environ["LOCALAPPDATA"] = old_appdata
        displays = request("displays")["value"]
        assert isinstance(displays, list)
        print(f"OBSERVED {len(displays)} Windows display descriptors; no peer session")


if __name__ == "__main__":
    main()
