# Helpers for install.sh. Sourced by install.sh and by tests/install_helpers_test.sh.

# Domain for local private-message mail (decided 2026-10-30). Existing mail is never rewritten.
BASHBBS_MAIL_DOMAIN=bbs.localdomain

# Dependencies: Debian package | required or optional | check, run with bash -c.
BASHBBS_DEPS=(
    "python3|required|command -v python3"
    "util-linux|required|command -v flock"
    "systemd|required|command -v systemctl"
    "openssh-server|required|command -v sshd"
    "postfix|optional|command -v postconf"
    "lighttpd|optional|command -v lighttpd"
    "fail2ban|optional|command -v fail2ban-client"
    # The jail bans through nft, so nftables is needed whenever fail2ban is installed.
    "nftables|optional|! command -v fail2ban-client >/dev/null || command -v nft >/dev/null"
    # fail2ban uses the systemd journal backend, which needs this Python module.
    "python3-systemd|optional|! command -v fail2ban-client >/dev/null || python3 -c 'import systemd.journal'"
)

# Prints the packages of one level (required or optional) whose check fails.
bashbbs_missing_deps() { # bashbbs_missing_deps <required|optional>
    local entry pkg rest level check
    for entry in "${BASHBBS_DEPS[@]}"; do
        pkg=${entry%%|*}
        rest=${entry#*|}
        level=${rest%%|*}
        check=${rest#*|}
        if [[ $level == "$1" ]] && ! bash -c "$check" >/dev/null 2>&1; then
            echo "$pkg"
        fi
    done
    return 0
}

# Prints the missing packages of both levels on one space-separated line, for apt-get.
bashbbs_missing_words() {
    { bashbbs_missing_deps required; bashbbs_missing_deps optional; } | tr '\n' ' '
}

# Postfix checks for private messages. Prints one WARNING line per deviation and changes
# nothing. Postfix is never edited automatically.
# Args: <myorigin> <mydestination> <home_mailbox> <mailname file>. myorigin is a domain,
# or a file path (the Debian default /etc/mailname), which is read for the domain.
bashbbs_postfix_warnings() {
    local origin=$1 dest=$2 mailbox=$3 mailname=$4 domain
    if [[ $origin == /* ]]; then
        domain=$(head -n1 "$mailname" 2>/dev/null || true)
    else
        domain=$origin
    fi
    [[ $domain == "$BASHBBS_MAIL_DOMAIN" ]] ||
        echo "WARNING: Postfix myorigin is '${domain:-unset}', must be '$BASHBBS_MAIL_DOMAIN'. Not changed by install.sh." >&2
    [[ $dest == *myhostname* ]] ||
        echo "WARNING: Postfix mydestination does not include \$myhostname. Check it before using private messages." >&2
    [[ $dest == *myorigin* || $dest == *"$BASHBBS_MAIL_DOMAIN"* ]] ||
        echo "WARNING: Postfix mydestination does not include \$myorigin ('$BASHBBS_MAIL_DOMAIN'). Check it before using private messages." >&2
    [[ $mailbox == Maildir/ ]] ||
        echo "WARNING: Postfix home_mailbox is '${mailbox:-unset}', must be 'Maildir/'. Private messages will not arrive. To set it: postconf -e 'home_mailbox = Maildir/' && systemctl reload postfix" >&2
    return 0
}

# Copies a config file that the sysop may have edited. A missing target is installed.
# A target that differs from the repo copy is kept, and the repo version goes to <target>.new.
keep_or_note() { # keep_or_note <repo file> <target>
    if [[ ! -e $2 ]]; then
        install -m 0644 "$1" "$2"
    elif ! cmp -s "$1" "$2"; then
        install -m 0644 "$1" "$2.new"
        echo "KEPT $2: differs from $1. New version: $2.new. Compare: diff $2 $2.new" >&2
    fi
}
