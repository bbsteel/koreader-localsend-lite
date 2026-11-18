"""Exercise both directions against the official LocalSend 1.18.2 terminal app."""
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time
import fcntl
from contextlib import contextmanager

cli, peer_script, scratch = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sender_folder = scratch / "outgoing"
sender_folder.mkdir()
payload = b"KOReader LocalSend\x00interop\n" * 45056
ansi_codes = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")

@contextmanager
def run(cli_destination, plugin_destination, mode, file):
    for folder in (cli_destination, plugin_destination):
        folder.mkdir()
    test_environment = dict(os.environ, TERM="xterm-256color", XDG_CONFIG_HOME=str(scratch / "cli-config"))
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 120, 0, 0))
    cli_command = [str(cli), "--alias", "Official LocalSend test", "--port", "53320",
                   "--destination", str(cli_destination)]
    if mode == "receive":
        cli_command.extend(["-f", str(file)])
    official = subprocess.Popen(cli_command, stdin=slave, stdout=slave, stderr=slave, env=test_environment)
    os.close(slave)
    plugin = subprocess.Popen(
        ["./luajit", str(peer_script), str(plugin_destination), mode, str(file)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    official_output = b""
    plugin_output = b""

    try:
        def await_output(received, timeout=14):
            nonlocal official_output, plugin_output
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                cli_text = ansi_codes.sub(b"", official_output).decode(errors="replace")
                lua_text = plugin_output.decode(errors="replace")
                if received(cli_text, lua_text):
                    return cli_text, lua_text
                if official.poll() is not None or plugin.poll() is not None:
                    break
                ready, _, _ = select.select([master, plugin.stdout], [], [], 0.1)
                for descriptor in ready:
                    try:
                        chunk = os.read(descriptor if descriptor == master else descriptor.fileno(), 65536)
                    except OSError:
                        chunk = b""
                    if descriptor == master:
                        official_output = (official_output + chunk)[-65536:]
                    else:
                        plugin_output = (plugin_output + chunk)[-65536:]
            cli_text = ansi_codes.sub(b"", official_output).decode(errors="replace")
            raise RuntimeError(f"Unexpected client state\nOfficial CLI: {cli_text[-5000:]}\nPlugin: {plugin_output.decode(errors='replace')}")
        yield await_output, master
    finally:
        for process in (official, plugin):
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        os.close(master)


plugin_file = sender_folder / "from-koreader.epub"
plugin_file.write_bytes(payload)
official_destination = scratch / "official-inbox"
with run(official_destination, scratch / "plugin-sending", "send", plugin_file) as (await_output, terminal):
    await_output(lambda output, _: "from-koreader.epub" in output)
    os.write(terminal, b"y")
    await_output(lambda _, output: "SENT\n" in output)
    assert (official_destination / plugin_file.name).read_bytes() == payload
    print("PASS: plugin → official LocalSend 1.18.2, HTTPS, byte-for-byte")

official_file = sender_folder / "from-official.epub"
official_file.write_bytes(payload)
plugin_destination = scratch / "plugin-inbox"
with run(scratch / "official-sending", plugin_destination, "receive", official_file) as (await_output, terminal):
    device_label = re.compile(r"\[(\d)\]\s+熱心的杏桃")
    cli_output, _ = await_output(lambda output, _: device_label.search(output))
    device_index = int(device_label.search(cli_output).group(1))
    os.write(terminal, b"\x1b[B" * (device_index - 1) + b"\r")
    await_output(lambda _, output: "RECEIVED " in output)
    assert (plugin_destination / official_file.name).read_bytes() == payload
    print("PASS: official LocalSend 1.18.2 → plugin, HTTPS, byte-for-byte")
