"""Normalize operator IPs into the allowlist ranges passed to the template.

Usage: client_ip_ranges.py PREFIX ADDRESS_OR_CIDR...

Corporate networks egress through several NAT addresses, and different Azure
front ends can see different ones, so every bare IPv4 address is widened to its
/PREFIX network. Explicit CIDRs are kept as given. Non-public and IPv6 entries
are dropped (Azure service firewalls accept public IPv4 only). Single hosts are
printed without /32 because Storage rejects /31 and /32 prefixes. Prints a JSON
array of collapsed ranges.
"""
import ipaddress
import json
import sys


def normalize(prefix, entries):
    networks = []
    for raw in entries:
        for token in raw.replace(",", " ").split():
            try:
                if "/" in token:
                    net = ipaddress.ip_network(token, strict=False)
                else:
                    net = ipaddress.ip_network(f"{token}/{prefix}", strict=False)
            except ValueError:
                continue
            if net.version == 4 and net.is_global:
                networks.append(net)
    collapsed = ipaddress.collapse_addresses(networks)
    return [str(n.network_address) if n.prefixlen == 32 else str(n) for n in collapsed]


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    prefix = int(argv[1])
    if not 8 <= prefix <= 32:
        print("PREFIX must be between 8 and 32", file=sys.stderr)
        return 2
    print(json.dumps(normalize(prefix, argv[2:])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
