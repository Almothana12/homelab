"""Discover host-network addresses, then replace this process with vLLM."""
import fcntl
import ipaddress
import os
import socket
import struct
import sys
import time
import urllib.request

def interface_ipv4(interface):
    name = interface.encode("ascii")
    if not name or len(name) > 15:
        raise ValueError("Expected a Linux interface name of 1-15 bytes")
    # SIOCGIFADDR is a read-only ioctl; no ip utility or NET_ADMIN is needed.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        result = fcntl.ioctl(sock.fileno(), 0x8915, struct.pack("256s", name))
    address = socket.inet_ntoa(result[20:24])
    ip = ipaddress.IPv4Address(address)
    if ip.is_loopback or ip.is_unspecified or ip.is_link_local or ip.is_multicast:
        raise ValueError(f"Interface {interface} has unsuitable IPv4 {address}")
    return address

def leader_ipv4(host, expected=None, timeout=300):
    deadline = time.monotonic() + timeout
    while True:
        try:
            addresses = sorted({item[4][0] for item in socket.getaddrinfo(
                host, None, socket.AF_INET, socket.SOCK_STREAM)})
            if len(addresses) == 1 and (expected is None or addresses[0] == expected):
                return addresses[0]
            reason = f"expected one leader IPv4 ({expected or 'any'}), got {addresses}"
        except socket.gaierror as exc:
            reason = str(exc)
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Leader discovery failed for {host}: {reason}")
        print(f"Waiting for leader DNS {host}: {reason}", flush=True)
        time.sleep(2)

def check_leader_health():
    # Direct per-group DNS, not the load-balanced API Service. No dependency
    # on Ready endpoints: the LWS discovery Service publishes unready pods.
    host = os.environ["LWS_LEADER_ADDRESS"]
    port = int(os.environ.get("API_PORT", "8000"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://{host}:{port}/health", timeout=3) as response:
        if response.status != 200:
            raise RuntimeError(f"Leader health returned {response.status}")

def launch(args):
    if "--master-addr" in args:
        raise ValueError("master-addr is managed by discovery, not model args")
    rank = int(os.environ["LWS_WORKER_INDEX"])
    pod_ip = str(ipaddress.IPv4Address(os.environ["POD_IP"]))
    interface = os.environ["INFERENCE_INTERFACE"]
    transport_ip = interface_ipv4(interface)
    leader = leader_ipv4(os.environ["LWS_LEADER_ADDRESS"],
                         expected=pod_ip if rank == 0 else None)
    env = dict(os.environ)
    env["VLLM_HOST_IP"] = transport_ip
    env["NCCL_SOCKET_IFNAME"] = "=" + interface
    env["GLOO_SOCKET_IFNAME"] = interface
    print(f"LWS rank={rank} pod_ip={pod_ip} leader={leader} "
          f"transport={interface}/{transport_ip}", flush=True)
    # Rendezvous uses leader management IPv4; NCCL/Gloo and vLLM advertised
    # endpoints use the selected direct-link interface. Never guess a peer IP.
    os.execvpe("vllm", ["vllm", "serve", *args, "--master-addr", leader], env)

if __name__ == "__main__":
    if sys.argv[1:] == ["--check-leader-health"]:
        check_leader_health()
    else:
        launch(sys.argv[1:])
