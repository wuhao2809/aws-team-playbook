# ⬇️ THIS IS THE FILE YOU EDIT ⬇️
#
# Add your public IP (from https://checkip.amazonaws.com/) as a /32
# entry. Include a comment with your name and team number.
#
# Example:
#   "198.51.100.42/32",   # Hao Wu — Team 3
#
# After your PR merges, GitHub Actions will apply this change and the
# ALB will start accepting traffic from your IP.

allowed_ips = [
  "203.0.113.10/32",   # instructor (do not remove)
  # add your line below
]
