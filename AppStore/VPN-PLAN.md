# Plan: a "Couchpad VPN" app (later, optional)

Couchpad itself ships **without** a VPN. This is what adding one would take, so you can decide later.

## Why it's a separate project

| | Couchpad (now) | A city VPN |
|---|---|---|
| Apple account | Individual ($99/yr) is fine | **Organization only** (App Store Guideline 5.4) – needs a registered business and a free D-U-N-S number |
| Servers | None – phone talks to your own Mac | **One rented server per city**, running 24/7 |
| Running cost | $0 | roughly **$5–10 per city per month**, plus bandwidth (heavy users can cost more than that each) |
| Responsibility | Your own devices | Other people's internet traffic leaves through **your** servers: abuse reports, copyright notices and law-enforcement requests go to you |
| App Review | Utility app | Extra review for VPN apps; must use Apple's `NEVPNManager` / Network Extension, have a clear privacy policy and no data selling |

It should be its **own app** (e.g. "Couchpad VPN"), not a feature inside the remote: mixing unrelated features makes review harder, and the remote would then also need the organization account.

## How it would be built

1. **Protocol:** WireGuard (fast, modern, open source). The iPhone/Mac app uses Apple's Network Extension (`NEPacketTunnelProvider`) with the official `wireguard-apple` library.
2. **Servers:** one small Linux VM per city at a provider with many locations (e.g. Vultr, DigitalOcean, Hetzner, AWS Lightsail). A setup script installs WireGuard, a firewall and automatic updates. Example starting set: New York, Los Angeles, Toronto, London, Frankfurt, Amsterdam, Paris, Tokyo, Singapore, Sydney (~$50–100/month in total).
3. **Accounts & keys:** a tiny API that hands each device its own WireGuard key for the city it picks (no logging of traffic). To keep strangers from using your servers for free forever, you'd likely want sign-in and a subscription (StoreKit) to cover costs.
4. **Privacy:** a no-logs policy you can actually keep (no traffic logs, minimal connection metadata, deleted quickly), written into the privacy policy.
5. **Apple entitlements:** Network Extension (Packet Tunnel) capability on the organization team.

## Rough effort

- Apps (iPhone + Mac, Network Extension, city picker, connect/disconnect, on-demand rules): a solid first version is a few focused sessions of work.
- Server automation + key API + monitoring: similar.
- Ongoing: server updates, abuse handling, paying the bills.

## If you just want a VPN for yourself

You don't need to build anything: install the free **WireGuard** app and either rent one server yourself (any provider above, ~$5/month) or use a commercial VPN. If you want to reach your **home** network while away, enabling WireGuard on your home router or using Tailscale (free for personal use) does that.

When you're ready to build "Couchpad VPN", say so and point me at this file.
