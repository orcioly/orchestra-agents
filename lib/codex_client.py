#!/usr/bin/env python3
# Orchestra Agents — cliente JSON-RPC do Codex app-server.
#
# Fala o protocolo experimental do `codex app-server` (v2) por um socket Unix
# (`codex app-server --listen unix://SOCK`), do mesmo jeito que o OpenCode expõe
# o servidor HTTP. É o análogo do despacho async do OpenCode para o backend Codex.
#
# Subcomandos:
#   start-thread --cwd DIR [--sandbox MODE] [--approval POLICY]
#                [--instructions TXT] [--model M]         -> imprime o threadId
#   dispatch     --thread TID --text TXT --last FILE --status FILE [--timeout N]
#                -> roda o turno ATÉ completar (pensado p/ rodar em background via setsid),
#                   escrevendo a resposta final em FILE e o estado (running|done|timeout|error)
#                   em STATUS. Também emite os eventos no stdout (para o painel monitorar).
#
# Não precisa de dependências externas: usa apenas a stdlib (socket AF_UNIX +
# JSON-RPC delimitado por linha). O texto final do assistente sai no evento
# `item/completed` com `item.type == "agentMessage"` (campo `text`).
import socket, json, sys, time, argparse, threading, struct, os, base64, hashlib
from urllib.parse import urlparse


# ---------------------------------------------------------------------------
# Cliente WebSocket mínimo (só stdlib). O codex app-server (`--listen unix://`
# ou `ws://host:port`) fala JSON-RPC v2 SOBRE WebSocket — o mesmo transporte que
# o `codex --remote` usa. Cada mensagem JSON-RPC é um frame de texto.
# ---------------------------------------------------------------------------
class _WS:
    def __init__(self, target, connect_timeout=20):
        # target: "unix://PATH" (ou PATH puro) ou "ws://host:port"
        host = "localhost"
        if target.startswith("ws://"):
            u = urlparse(target)
            host = u.hostname or "localhost"
            s = socket.create_connection((u.hostname, u.port or 80), timeout=connect_timeout)
        else:
            path = target[len("unix://"):] if target.startswith("unix://") else target
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(connect_timeout)
            s.connect(path)
        s.settimeout(connect_timeout)
        self._s = s
        self._buf = b""
        self._handshake(host)
        self._s.settimeout(None)

    def _handshake(self, host):
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET / HTTP/1.1\r\n"
               f"Host: {host}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self._s.sendall(req.encode())
        # lê headers até \r\n\r\n
        while b"\r\n\r\n" not in self._buf:
            chunk = self._s.recv(4096)
            if not chunk:
                raise RuntimeError("app-server fechou durante o handshake WebSocket")
            self._buf += chunk
        head, _, rest = self._buf.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError(f"handshake WebSocket falhou: {head[:80]!r}")
        # valida accept (opcional, mas barato)
        acc = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self._buf = rest

    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self._s.recv(65536)
            if not chunk:
                raise ConnectionError("EOF no WebSocket")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send_text(self, text):
        payload = text.encode()
        n = len(payload)
        header = bytearray([0x81])  # FIN + opcode text
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126); header += struct.pack("!H", n)
        else:
            header.append(0x80 | 127); header += struct.pack("!Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._s.sendall(bytes(header) + masked)

    def recv_message(self):
        """Retorna o próximo texto JSON completo (lida com fragmentação/ping/close)."""
        data = bytearray()
        while True:
            b0 = self._read_exact(1)[0]
            b1 = self._read_exact(1)[0]
            fin = b0 & 0x80
            opcode = b0 & 0x0f
            masked = b1 & 0x80
            length = b1 & 0x7f
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length) if length else b""
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:            # close
                raise ConnectionError("WebSocket fechado pelo servidor")
            if opcode == 0x9:            # ping -> pong
                self._send_ctrl(0xA, payload); continue
            if opcode == 0xA:            # pong
                continue
            data += payload
            if fin:
                return data.decode("utf-8", "replace")

    def _send_ctrl(self, opcode, payload=b""):
        header = bytearray([0x80 | opcode, 0x80 | len(payload)])
        mask = os.urandom(4)
        header += mask
        header += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._s.sendall(bytes(header))

    def close(self):
        try:
            self._send_ctrl(0x8)
        except Exception:
            pass
        try:
            self._s.close()
        except Exception:
            pass


class Client:
    """Cliente JSON-RPC do codex app-server sobre WebSocket."""

    def __init__(self, target, connect_timeout=20):
        self._ws = _WS(target, connect_timeout)
        self._id = 0
        self._resp = {}
        self._notifs = []
        self._lock = threading.Lock()
        self._alive = True
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        try:
            while True:
                text = self._ws.recv_message()
                try:
                    o = json.loads(text)
                except Exception:
                    continue
                if "id" in o and ("result" in o or "error" in o):
                    with self._lock:
                        self._resp[o["id"]] = o
                elif o.get("method"):
                    with self._lock:
                        self._notifs.append(o)
        except Exception:
            pass
        self._alive = False

    def call(self, method, params=None, timeout=60):
        with self._lock:
            self._id += 1
            rid = self._id
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self._ws.send_text(json.dumps(msg))
        t0 = time.time()
        while time.time() - t0 < timeout:
            with self._lock:
                if rid in self._resp:
                    r = self._resp.pop(rid)
                    if "error" in r:
                        raise RuntimeError(f"RPC {method}: {r['error']}")
                    return r.get("result")
            if not self._alive:
                raise RuntimeError(f"conexão caiu antes de responder {method}")
            time.sleep(0.05)
        raise TimeoutError(f"timeout aguardando {method}")

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self._ws.send_text(json.dumps(msg))

    def initialize(self):
        self.call("initialize", {"clientInfo": {"name": "orchestra", "version": "0.1.0"}})
        self.notify("initialized", {})

    def drain_notifs(self):
        with self._lock:
            n = self._notifs[:]
            self._notifs.clear()
        return n

    def close(self):
        try:
            self._ws.close()
        except Exception:
            pass


def _emit(msg):
    print(msg, flush=True)


def _run_turn(c, tid, text, timeout):
    """Roda um turno até completar; retorna (texto_final, concluido)."""
    c.call("turn/start", {"threadId": tid, "input": [{"type": "text", "text": text}]})
    chunks = []
    done = False
    t0 = time.time()
    while time.time() - t0 < timeout and not done:
        for o in c.drain_notifs():
            m = o.get("method")
            if m == "item/completed":
                it = o.get("params", {}).get("item", {})
                if it.get("type") == "agentMessage" and it.get("text"):
                    chunks.append(it["text"])
            elif m == "turn/completed":
                done = True
            elif m == "error":
                done = True
        if not done:
            time.sleep(0.2)
    return "\n".join(chunks).strip(), done


# turno mínimo de "priming": o codex só grava o rollout do thread em disco DEPOIS
# do primeiro turno. Sem isso, nem o dispatch (conexão nova) nem a TUI (`codex
# --remote resume`) conseguem retomar o thread ("no rollout found").
_PRIME_PROMPT = ("Sessão iniciada pelo Orchestra. Ainda não há tarefa — "
                 "não faça nada e responda apenas com a palavra: pronto")


def cmd_start_thread(args):
    c = Client(args.sock)
    try:
        c.initialize()
        params = {"cwd": args.cwd, "approvalPolicy": args.approval}
        if args.sandbox:
            params["sandbox"] = args.sandbox
        if args.instructions:
            params["developerInstructions"] = args.instructions
        if args.model:
            params["model"] = args.model
        r = c.call("thread/start", params)
        th = r.get("thread")
        tid = th.get("id") if isinstance(th, dict) else th
        # priming: persiste o rollout para que resume (dispatch/TUI) funcione depois
        if tid and not args.no_prime:
            try:
                _run_turn(c, tid, _PRIME_PROMPT, args.prime_timeout)
            except Exception:
                pass  # se o priming falhar, ainda devolvemos o tid (dispatch tenta start)
        print(tid)
    finally:
        c.close()


def cmd_dispatch(args):
    def setstatus(s):
        with open(args.status, "w") as f:
            f.write(s)

    setstatus("running")
    try:
        c = Client(args.sock)
    except Exception as e:
        setstatus("error")
        with open(args.last, "w") as f:
            f.write(f"[ERRO] não conectei ao codex app-server: {e}")
        return
    try:
        c.initialize()
        # retoma o thread do papel (mesma sessão que a TUI --remote enxerga)
        c.call("thread/resume", {"threadId": args.thread})
        c.call("turn/start", {
            "threadId": args.thread,
            "input": [{"type": "text", "text": args.text}],
        })
        _emit(f"[codex] turno iniciado no thread {args.thread}")
        chunks = []
        t0 = time.time()
        done = False
        errored = False
        while time.time() - t0 < args.timeout and not done:
            for o in c.drain_notifs():
                m = o.get("method")
                if m == "item/started":
                    it = o.get("params", {}).get("item", {})
                    t = it.get("type")
                    if t == "commandExecution":
                        _emit("[codex] executando comando...")
                    elif t == "fileChange":
                        _emit("[codex] editando arquivos...")
                    elif t == "reasoning":
                        _emit("[codex] pensando...")
                elif m == "item/completed":
                    it = o.get("params", {}).get("item", {})
                    if it.get("type") == "agentMessage" and it.get("text"):
                        chunks.append(it["text"])
                        _emit("[codex] mensagem do agente recebida")
                elif m == "turn/completed":
                    done = True
                elif m == "error":
                    errored = True
                    _emit("[codex] ERRO: " + json.dumps(o.get("params", {}))[:300])
                    done = True
            if not done:
                time.sleep(0.2)
        text = "\n".join(chunks).strip()
        with open(args.last, "w") as f:
            f.write(text)
        if errored:
            setstatus("error")
        elif done:
            setstatus("done")
            _emit("[codex] ✔ turno concluído")
        else:
            setstatus("timeout")
            _emit("[codex] ⚠ timeout")
    except Exception as e:
        setstatus("error")
        with open(args.last, "w") as f:
            f.write(f"[ERRO] {e}")
    finally:
        c.close()


def cmd_ping(args):
    # healthcheck: conecta via WebSocket e faz initialize. exit 0 se ok, 1 se não.
    try:
        c = Client(args.sock, connect_timeout=4)
        c.call("initialize", {"clientInfo": {"name": "orchestra", "version": "0.1.0"}}, timeout=5)
        c.close()
        sys.exit(0)
    except Exception:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(prog="codex_client")
    ap.add_argument("--sock", required=True, help="caminho do socket Unix do app-server")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")

    p1 = sub.add_parser("start-thread")
    p1.add_argument("--cwd", required=True)
    p1.add_argument("--sandbox", default=None,
                    choices=["read-only", "workspace-write", "danger-full-access"])
    p1.add_argument("--approval", default="never",
                    choices=["untrusted", "on-request", "never"])
    p1.add_argument("--instructions", default=None)
    p1.add_argument("--model", default=None)
    p1.add_argument("--no-prime", action="store_true",
                    help="não roda o turno de priming (rollout pode não persistir)")
    p1.add_argument("--prime-timeout", type=int, default=60)

    p2 = sub.add_parser("dispatch")
    p2.add_argument("--thread", required=True)
    p2.add_argument("--text", required=True)
    p2.add_argument("--last", required=True)
    p2.add_argument("--status", required=True)
    p2.add_argument("--timeout", type=int, default=600)

    args = ap.parse_args()
    if args.cmd == "start-thread":
        cmd_start_thread(args)
    elif args.cmd == "dispatch":
        cmd_dispatch(args)
    elif args.cmd == "ping":
        cmd_ping(args)


if __name__ == "__main__":
    main()
