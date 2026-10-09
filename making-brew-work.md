# Brew installation troubleshooting README

**Session ID:** ses_ee41cf66effeYICWbL8ycID8fc
**Created:** 10/8/2026, 8:20:26 AM
**Updated:** 10/8/2026, 8:20:27 AM

---

## User

look at @README.md 

it has instructions for installing this project with brew.  the make from source worked but brew failed.  would there be extra steps needed for brew to work that aren't listed in the readme?

---

## Assistant

Yes, there are several steps missing from the README. The command `brew install --HEAD barkbarkgoose/tap/xem` fails primarily because **the Homebrew tap repository does not exist yet (or isn't accessible via HTTPS)**.

Here is why it failed and the extra steps needed to make Homebrew work:

---

### Why it failed

1. **The tap repository `barkbarkgoose/homebrew-tap` doesn't exist on GitHub**
   * When you run `brew install ... barkbarkgoose/tap/xem`, Homebrew tries to automatically clone `https://github.com/barkbarkgoose/homebrew-tap`.
   * That repository does not currently exist on GitHub (referenced only as a future release step in the README: *"3. Copy the formula into the homebrew-tap repo and push"*).

2. **Homebrew clones taps over HTTPS by default**
   * Even if `barkbarkgoose/homebrew-tap` were created as a **private** repository, Homebrew's auto-tap runs with `GIT_TERMINAL_PROMPT=0` over HTTPS. Private GitHub repositories return a 404 error unless explicitly tapped via SSH first.

3. **Modern Homebrew (4.0+) rejects direct file paths**
   * You cannot simply run `brew install Formula/xem.rb`; Homebrew requires all formulae to exist inside a registered tap.

4. **SSH Agent requirement for `--HEAD`**
   * `Formula/xem.rb` specifies:
     ```ruby
     head "ssh://git@github.com/barkbarkgoose/xem-mac.git", branch: "main", using: :git
     ```
   * Because Homebrew runs non-interactively, your SSH key must already be loaded into `ssh-agent` (`ssh-add -l`), otherwise git will fail during the clone.

---

### How to make Homebrew work

#### Option 1: Test / install locally with a local tap (Recommended for local dev)

You can create a local tap without publishing anything to GitHub:

```sh
# 1. Initialize a local tap
brew tap-new local/tap

# 2. Copy the formula into the local tap directory
cp Formula/xem.rb "$(brew --repository)/Library/Taps/local/homebrew-tap/Formula/xem.rb"

# 3. Ensure your SSH key is active for the private xem-mac repo clone
ssh-add --apple-use-keychain ~/.ssh/id_ed25519  # or your respective key

# 4. Install via the local tap
brew install --HEAD local/tap/xem
```

#### Option 2: If publishing the tap to GitHub

1. Create a GitHub repo named `homebrew-tap` under the `barkbarkgoose` account.
2. Put `Formula/xem.rb` in that repo under a `Formula/` directory and push.
3. If the tap repo is **private**, tap it via SSH first before running `brew install`:
   ```sh
   brew tap barkbarkgoose/tap git@github.com:barkbarkgoose/homebrew-tap.git
   brew install --HEAD barkbarkgoose/tap/xem
   ```
4. If the tap repo is **public**, the README command (`brew install --HEAD barkbarkgoose/tap/xem`) will work as written (provided the user has SSH access to `xem-mac` for the `--HEAD` clone).
