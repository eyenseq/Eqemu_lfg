package plugin;

use JSON::PP qw(encode_json decode_json);

# ============================================================
# LFG / LFM Plugin (older EQEmu safe)
#
# - No entity list lookups
# - No server-side GroupInvite()
# - Pending invite NAME-based only
# - Cross-zone inbox messages
# - Auto-port on accept (via group events)
#
# Commands (/say):
#   ?lfg <min>-<max> [role|auto] <note...>
#   ?lfg list
#   ?lfg clear
#   ?lfg consent on|off
#   ?lfg tell <name>
#
#   ?lfm [label] <min>-<max> need:<roles> <note...>
#   ?lfm list
#   ?lfm clear [label|all]
#   ?lfm tell <name>
#
# Roles supported:
#   tank | healer | dps | cc | pull | support
#
# ============================================================

# ------------------- Tunables -------------------
our $TTL_SECONDS              = 60 * 60 * 2;    # listing lifetime: 2 hours
our $PEND_TTL_SECONDS         = 60 * 10;        # pending marker: 10 minutes
our $PEND_MAX_AGE_SECONDS     = 60 * 5;         # must accept/port within 5 minutes of snapshot
our $INVITE_COOLDOWN_SECONDS  = 30;             # per leader+target cooldown
our $LIST_MAX_SHOW            = 60;             # list cap
our $MAX_NOTE_LEN             = 80;
our $MAX_ROLE_LEN             = 16;

# Anti-teleport abuse toggle
our $ALLOW_CROSS_ZONE_PORT    = 1;              # 1 = allow cross-zone port, 0 = same-zone only

# Zone blacklist
our %ZONE_BLACKLIST = map { $_ => 1 } (
    # 76 => 1,  # example: bazaar
);

# ------------------- Keys -------------------
sub _key_lfg        { my ($cid) = @_; return "LFG:$cid"; }
sub _key_lfm        { my ($cid, $label) = @_; $label ||= 'main'; return "LFM:$cid:" . lc($label); }

sub _key_lfg_index  { return "LFG:INDEX"; }         # JSON array of charids
sub _key_lfm_index  { return "LFM:INDEX"; }         # JSON array of "cid:label"

sub _key_pend_name  { my ($name) = @_; return "LFGPENDNAME:" . lc($name // ""); }  # JSON snapshot
sub _key_consent    { my ($cid)  = @_; return "LFGCONSENT:$cid"; }                 # "1" or "0"
sub _key_cd_inv     { my ($leader_cid, $target_lc) = @_; return "LFGCD:$leader_cid:$target_lc"; }

# Inbox keys (name-based)
sub _key_inbox_name { my ($name) = @_; return "LFGINBOX:" . lc($name // ""); }
sub _key_hasmail    { my ($name) = @_; return "LFGHASMAIL:" . lc($name // ""); }

# ------------------- Basic helpers -------------------
sub _now { return time(); }

sub _invitee_cancel_pending {
    my ($client) = @_;
    return if !$client;

    my $me = _client_name($client);
    if (!$me || $me eq '') {
        _sysmsg($client, "Can't determine your name.");
        return;
    }

    my $pend_key = _key_pend_name($me);
    my $raw = _get_bucket($pend_key);

    if (!defined $raw || $raw eq '') {
        _sysmsg($client, "You have no pending invite to cancel.");
        return;
    }

    my $snap = _safe_decode($raw);
    my $leader = "Unknown";
    if ($snap && ref($snap) eq 'HASH') {
        $leader = $snap->{leader_name} // "Unknown";
    }

    _del_bucket($pend_key);
    _sysmsg($client, "Canceled pending invite from $leader.");
}

sub _set_bucket {
    my ($key, $val, $ttl) = @_;
    $ttl //= $TTL_SECONDS;
    quest::set_data($key, $val, $ttl);
}

sub _get_bucket { my ($key) = @_; return quest::get_data($key); }
sub _del_bucket { my ($key) = @_; quest::delete_data($key); }

sub _client_name { my ($c) = @_; return $c ? $c->GetCleanName() : ""; }
sub _char_id     { my ($c) = @_; return $c ? $c->CharacterID()  : 0; }
sub _level       { my ($c) = @_; return $c ? $c->GetLevel()     : 0; }

sub _say {
    my ($client, $msg) = @_;
    return if !$client;
    $client->Message(15, $msg);
}

sub _sysmsg {
    my ($client, $msg) = @_;
    return if !$client;
    $client->Message(15, "[LFG] $msg");
}

sub _link {
    my ($cmd, $label) = @_;
    $label //= $cmd;
    return quest::saylink($cmd, 1, $label);
}

sub _safe_decode {
    my ($json) = @_;
    return undef if !defined $json || $json eq '';
    my $v;
    eval { $v = decode_json($json); 1 } or return undef;
    return $v;
}

sub _parse_range {
    my ($range) = @_;
    return (undef, undef) if !defined $range;
    if ($range =~ /^\s*(\d{1,3})\s*-\s*(\d{1,3})\s*$/) {
        return ($1, $2);
    }
    return (undef, undef);
}

sub _norm_note {
    my ($s) = @_;
    $s //= '';
    $s =~ s/^\s+|\s+$//g;
    $s = substr($s, 0, $MAX_NOTE_LEN);
    return $s;
}

sub _norm_role {
    my ($s) = @_;
    $s //= '';
    $s =~ s/^\s+|\s+$//g;
    $s = lc($s);
    $s = substr($s, 0, $MAX_ROLE_LEN);
    return $s;
}

sub _is_leader {
    my ($client) = @_;
    return 0 if !$client;
    my $g = $client->GetGroup();
    return 0 if !$g;

    my $leader = $g->GetLeader();
    return 0 if !$leader;

    my $leader_name = eval { $leader->GetName() } || "";
    return 0 if $leader_name eq "";

    return (lc($leader_name) eq lc($client->GetName())) ? 1 : 0;
}

# ============================================================
# Multi-role by class + best-fit selection
# ============================================================

sub _auto_roles_from_class {
    my ($client) = @_;
    return ["dps"] if !$client;

    my $c = $client->GetClass();

    my %roles = (
        1  => [qw(tank)],                       # Warrior
        2  => [qw(healer)],                     # Cleric
        3  => [qw(tank healer support)],        # Paladin
        4  => [qw(dps pull)],                   # Ranger
        5  => [qw(tank dps)],                   # Shadowknight
        6  => [qw(healer dps)],                 # Druid
        7  => [qw(pull dps)],                   # Monk
        8  => [qw(support cc pull)],            # Bard
        9  => [qw(dps pull)],                   # Rogue
        10 => [qw(healer support)],             # Shaman
        11 => [qw(dps)],                        # Necromancer
        12 => [qw(dps)],                        # Wizard
        13 => [qw(dps)],                        # Magician
        14 => [qw(cc support)],                 # Enchanter
        15 => [qw(dps support)],                # Beastlord
        16 => [qw(dps)],                        # Berserker
    );

    return $roles{$c} // ["dps"];
}

sub _primary_role {
    my ($roles) = @_;
    return "dps" if ref($roles) ne 'ARRAY' || !@$roles;

    for my $p (qw(healer tank cc support pull dps)) {
        return $p if grep { $_ eq $p } @$roles;
    }
    return $roles->[0];
}

# Pick best-fit role based on leader's remaining needs
sub _best_role_for_needs {
    my ($roles, $needs_rem) = @_;
    return "dps" if ref($roles) ne 'ARRAY' || !@$roles;
    return _primary_role($roles) if ref($needs_rem) ne 'HASH' || !%$needs_rem;

    # Priority order (feel free to tweak)
    for my $p (qw(healer tank cc pull support dps)) {
        next if !grep { $_ eq $p } @$roles;
        next if !exists $needs_rem->{$p};
        next if ($needs_rem->{$p} // 0) <= 0;
        return $p;
    }

    # If no remaining needs match, fallback to primary
    return _primary_role($roles);
}

# Decrement remaining needs using selected role first, then any role match
sub _decrement_need_best {
    my ($needs_rem, $role_sel, $roles_all) = @_;
    return 0 if ref($needs_rem) ne 'HASH';

    $role_sel = _norm_role($role_sel // '');
    if ($role_sel ne '' && exists $needs_rem->{$role_sel} && ($needs_rem->{$role_sel} // 0) > 0) {
        $needs_rem->{$role_sel}--;
        $needs_rem->{$role_sel} = 0 if $needs_rem->{$role_sel} < 0;
        return 1;
    }

    return 0 if ref($roles_all) ne 'ARRAY';
    for my $r (@$roles_all) {
        next if !defined $r;
        $r = _norm_role($r);
        next if $r eq '';
        if (exists $needs_rem->{$r} && ($needs_rem->{$r} // 0) > 0) {
            $needs_rem->{$r}--;
            $needs_rem->{$r} = 0 if $needs_rem->{$r} < 0;
            return 1;
        }
    }

    return 0;
}

# ============================================================
# Anti-spam for notify/tell
# ============================================================

sub _key_tell_cd {
    my ($from, $to) = @_;
    return "LFGTELLCD:" . lc($from // "") . ":" . lc($to // "");
}

sub _tell_on_cooldown {
    my ($from, $to) = @_;
    return (quest::get_data(_key_tell_cd($from, $to)) // "") ne "";
}

sub _set_tell_cooldown {
    my ($from, $to, $sec) = @_;
    $sec ||= 25;
    quest::set_data(_key_tell_cd($from, $to), "1", $sec);
}

sub _key_tell_burst {
    my ($from) = @_;
    return "LFGTELLBURST:" . lc($from // "");
}

sub _tell_burst_ok {
    my ($from) = @_;
    my $k = _key_tell_burst($from);
    my $n = quest::get_data($k);
    $n = 0 if !defined $n || $n !~ /^\d+$/;

    return 0 if $n >= 6;          # max 6 notifies per 60 seconds
    quest::set_data($k, $n + 1, 60);
    return 1;
}

# ============================================================
# Inbox + has-mail flag (name-based, cross-zone)
# ============================================================

sub _mark_has_mail {
    my ($to_name) = @_;
    return if !$to_name || $to_name eq '';
    quest::set_data(_key_hasmail($to_name), "1", 60 * 60 * 24);
}

sub lfg_has_mail {
    my ($client) = @_;
    return 0 if !$client;
    my $me = _client_name($client);
    return 0 if $me eq '';
    my $v = quest::get_data(_key_hasmail($me));
    return (defined $v && $v eq "1") ? 1 : 0;
}

sub lfg_clear_has_mail {
    my ($client) = @_;
    return if !$client;
    my $me = _client_name($client);
    return if $me eq '';
    quest::delete_data(_key_hasmail($me));
}

sub _inbox_push_name {
    my ($to_name, $from_name, $msg) = @_;
    return 0 if !defined $to_name || $to_name eq '';

    my $key = _key_inbox_name($to_name);
    my $arr = _safe_decode(_get_bucket($key));
    $arr = [] if ref($arr) ne 'ARRAY';

    push @$arr, {
        from => ($from_name // "Unknown"),
        msg  => ($msg // ""),
        ts   => _now(),
    };

    shift @$arr while @$arr > 10;

    _set_bucket($key, encode_json($arr), 60 * 60 * 24);
    _mark_has_mail($to_name);
    return 1;
}

sub lfg_deliver_inbox {
    my ($client) = @_;
    return if !$client;

    my $me = _client_name($client);
    return if $me eq '';

    my $key = _key_inbox_name($me);
    my $arr = _safe_decode(_get_bucket($key));
    return if ref($arr) ne 'ARRAY' || !@$arr;

    foreach my $m (@$arr) {
        next if ref($m) ne 'HASH';
        my $from = $m->{from} // "Unknown";
        my $txt  = $m->{msg}  // "";
        $client->Message(15, "[LFG] From $from: $txt");
    }

    _del_bucket($key);
    lfg_clear_has_mail($client);
}

# ============================================================
# Index helpers
# ============================================================

sub _load_index {
    my ($key) = @_;
    my $raw = _get_bucket($key);
    my $arr = _safe_decode($raw);
    $arr = [] if ref($arr) ne 'ARRAY';
    return $arr;
}

sub _save_index {
    my ($key, $arrref) = @_;
    $arrref = [] if ref($arrref) ne 'ARRAY';
    _set_bucket($key, encode_json($arrref), $TTL_SECONDS);
}

sub _idx_add_unique {
    my ($key, $val) = @_;
    return if !defined $val || $val eq '';
    my $arr = _load_index($key);
    my %seen = map { $_ => 1 } @$arr;
    if (!$seen{$val}) {
        push @$arr, $val;
        _save_index($key, $arr);
    }
}

sub _idx_remove_value {
    my ($key, $val) = @_;
    return if !defined $val || $val eq '';
    my $arr = _load_index($key);
    my @out = grep { $_ ne $val } @$arr;
    _save_index($key, \@out);
}

sub _idx_prune_missing_lfg {
    my ($arrref) = @_;
    my @out;
    foreach my $cid (@$arrref) {
        my $raw = _get_bucket(_key_lfg($cid));
        next if !defined $raw || $raw eq '';
        push @out, $cid;
    }
    return \@out;
}

sub _idx_prune_missing_lfm {
    my ($arrref) = @_;
    my @out;
    foreach my $token (@$arrref) {
        my ($cid, $label) = split(/:/, $token, 2);
        next if !$cid || !$label;
        my $raw = _get_bucket(_key_lfm($cid, $label));
        next if !defined $raw || $raw eq '';
        push @out, $token;
    }
    return \@out;
}

# ============================================================
# Needs parsing + labels
# ============================================================

sub _parse_needs_counts {
    my ($s) = @_;
    $s //= '';
    my %map = (
        heal => 'healer', healer => 'healer', cleric => 'healer',
        tank => 'tank', warrior => 'tank', war => 'tank',
        dps  => 'dps', dd => 'dps',
        cc   => 'cc', mez => 'cc',
        pull => 'pull', puller => 'pull',
        sup  => 'support', support => 'support', bard => 'support',
    );

    my %need = ();
    my $lc = lc($s);
    return \%need if $lc !~ /need:/;

    my ($list) = $lc =~ /need:\s*([a-z0-9=,_\s]+)/;
    $list //= '';
    $list =~ s/\s+//g;

    foreach my $tok (split(/,/, $list)) {
        next if $tok eq '';
        my ($r, $n) = split(/=/, $tok, 2);
        $r //= '';
        $n = defined $n ? $n : 1;
        $r = $map{$r} // $r;
        next if $r eq '';

        $n = 1 if $n !~ /^\d+$/;
        $n = 1 if $n < 1;
        $n = 9 if $n > 9;

        $need{$r} += $n;
    }

    return \%need;
}

sub _needs_to_label {
    my ($need_hash) = @_;
    return "" if ref($need_hash) ne 'HASH' || !%$need_hash;

    my @order = qw(healer tank cc pull support dps);
    my %seen;
    my @pairs;

    foreach my $r (@order) {
        next if !exists $need_hash->{$r};
        my $c = $need_hash->{$r};
        push @pairs, ($c > 1 ? "$r=$c" : $r);
        $seen{$r} = 1;
    }
    foreach my $r (sort keys %$need_hash) {
        next if $seen{$r};
        my $c = $need_hash->{$r};
        push @pairs, ($c > 1 ? "$r=$c" : $r);
    }

    return "need:" . join(",", @pairs);
}

sub _needs_all_filled {
    my ($need_hash) = @_;
    return 1 if ref($need_hash) ne 'HASH';
    foreach my $k (keys %$need_hash) {
        return 0 if ($need_hash->{$k} // 0) > 0;
    }
    return 1;
}

# ============================================================
# Find LFG entry by name using index
# ============================================================

sub _find_lfg_by_name_in_index {
    my ($name) = @_;
    return undef if !defined $name || $name eq '';
    my $nlc = lc($name);

    my $idx = _load_index(_key_lfg_index());
    my @keep;
    my $found;

    foreach my $cid (@$idx) {
        my $raw = _get_bucket(_key_lfg($cid));
        if (!defined $raw || $raw eq '') {
            next;
        }
        push @keep, $cid;

        my $p = _safe_decode($raw);
        next if !$p || ref($p) ne 'HASH';
        next if lc($p->{name} // '') ne $nlc;

        $found = $p;
    }

    if (@keep != @$idx) {
        _save_index(_key_lfg_index(), \@keep);
    }

    return $found;
}

# ============================================================
# Public: EVENT_SAY handler
# ============================================================

sub lfg_handle_say {
    my ($client, $text) = @_;
    return 0 if !$client || !defined $text;
    return 0 if $text !~ /^\s*\?(lfg|lfm)\b/i;

    my $cid = _char_id($client);
    my $me_name = _client_name($client);

    my ($cmd, $rest) = $text =~ /^\s*\?(\w+)\s*(.*)$/;
    $cmd  = lc($cmd // '');
    $rest = $rest // '';

    # ------------------- LFG -------------------
    if ($cmd eq 'lfg') {

        if ($rest =~ /^\s*consent\s+(on|off)\s*$/i) {
            my $v = lc($1) eq 'on' ? "1" : "0";
            _set_bucket(_key_consent($cid), $v, 60 * 60 * 24 * 30);
            _say($client, "LFG auto-port consent set to " . ( $v eq "1" ? "ON" : "OFF" ) . ".");
            return 1;
        }

        if ($rest =~ /^\s*tell\s+(\S+)\s*$/i) {
            my $to   = $1;
            my $from = $me_name;
            my $lvl  = _level($client);

            if (_tell_on_cooldown($from, $to)) {
                _say($client, "Slow down—please wait before notifying $to again.");
                return 1;
            }
            if (!_tell_burst_ok($from)) {
                _say($client, "Slow down—too many notifies. Try again in a minute.");
                return 1;
            }
            _set_tell_cooldown($from, $to, 25);

            my $roles = _auto_roles_from_class($client);
            my $role_txt = join(", ", @$roles);

            my $target = _find_lfg_by_name_in_index($to);
            my $tr = $target ? (($target->{min} // "?") . "-" . ($target->{max} // "?") . ", " . ($target->{role_primary} // "dps")) : "your listing";

            my $msg = "Hi! I saw your LFG listing ($tr). I'm lvl $lvl and can fill: $role_txt.";
            my $ok = _inbox_push_name($to, $from, $msg);

            _say($client, $ok ? "Notified $to." : "Couldn't notify $to.");
            return 1;
        }

        if ($rest =~ /^\s*list\s*$/i)  { _list_ads($client, 'LFG'); return 1; }
        
		if ($rest =~ /^\s*clear\s*$/i) { _del_bucket(_key_lfg($cid)); _idx_remove_value(_key_lfg_index(), $cid); _say($client, "LFG cleared."); return 1; }
		
		if ($rest =~ /^\s*cancel\s*$/i) {
			_invitee_cancel_pending($client);
			return 1;
		}

        if ($rest =~ /^\s*invite\s+(\S+)\s*$/i) {
            _invite_and_mark_pending($client, $1);
            return 1;
        }

        # post: ?lfg <min>-<max> [role|auto] <note...>
        my @parts = split(/\s+/, $rest);
        my $range = shift @parts;

        my $maybe_role = $parts[0] // "";
        my $role_tok = "";
        if ($maybe_role =~ /^(tank|healer|dps|cc|pull|support|auto)$/i) {
            $role_tok = _norm_role(shift @parts);
        } else {
            $role_tok = "auto";
        }

        my $note  = _norm_note(join(' ', @parts));
        my ($minl, $maxl) = _parse_range($range);
        if (!defined $minl || !defined $maxl) {
            _say($client, "Usage: ?lfg <min>-<max> [role|auto] <note...>");
            _say($client, "Example: ?lfg 20-30 auto need group");
            return 1;
        }

        my ($roles, $primary);
        if ($role_tok eq '' || $role_tok eq 'auto') {
            $roles   = _auto_roles_from_class($client);
            $primary = _primary_role($roles);
        } else {
            # explicit override -> single-role
            $primary = $role_tok;
            $roles   = [$primary];
        }

        # Default consent ON when posting LFG
        my $cons = _get_bucket(_key_consent($cid));
        if (!defined $cons || $cons eq '') {
            _set_bucket(_key_consent($cid), "1", 60 * 60 * 24 * 30);
        }

        my %payload = (
            name         => $me_name,
            cid          => $cid,
            lvl          => _level($client),
            min          => $minl,
            max          => $maxl,
            role_primary => $primary,
            roles        => $roles,
            note         => $note,
            zone         => $client->GetZoneID(),
            ts           => _now(),
        );

        _set_bucket(_key_lfg($cid), encode_json(\%payload), $TTL_SECONDS);
        _idx_add_unique(_key_lfg_index(), $cid);

        _say($client, "LFG posted: $minl-$maxl $primary - $note");
        return 1;
    }

    # ------------------- LFM -------------------
    if ($cmd eq 'lfm') {

        if ($rest =~ /^\s*list\s*$/i) { _list_ads($client, 'LFM'); return 1; }

        if ($rest =~ /^\s*tell\s+(\S+)\s*$/i) {
            my $to   = $1;
            my $from = $me_name;
            my $lvl  = _level($client);

            if (_tell_on_cooldown($from, $to)) {
                _say($client, "Slow down—please wait before notifying $to again.");
                return 1;
            }
            if (!_tell_burst_ok($from)) {
                _say($client, "Slow down—too many notifies. Try again in a minute.");
                return 1;
            }
            _set_tell_cooldown($from, $to, 25);

            my $roles = _auto_roles_from_class($client);
            my $role_txt = join(", ", @$roles);

            my $msg = "Hi! I saw your LFM listing. I'm lvl $lvl and can fill: $role_txt.";
            my $ok = _inbox_push_name($to, $from, $msg);

            _say($client, $ok ? "Notified $to." : "Couldn't notify $to.");
            return 1;
        }

        if ($rest =~ /^\s*clear(?:\s+(\S+))?\s*$/i) {
            my $arg = lc($1 // 'main');
            if ($arg eq 'all') {
                my $idx = _load_index(_key_lfm_index());
                my @mine = grep { /^\Q$cid\E:/ } @$idx;
                foreach my $tok (@mine) {
                    my ($tcid, $label) = split(/:/, $tok, 2);
                    _del_bucket(_key_lfm($tcid, $label));
                    _idx_remove_value(_key_lfm_index(), $tok);
                }
                _say($client, "LFM cleared (all listings).");
            } else {
                _del_bucket(_key_lfm($cid, $arg));
                _idx_remove_value(_key_lfm_index(), "$cid:$arg");
                _say($client, "LFM cleared ($arg).");
            }
            return 1;
        }

        # post:
        my @parts = split(/\s+/, $rest);

        my $maybe1 = $parts[0] // '';
        my $label = 'main';
        my $range;
        my $needs_str;

        my ($tmin, $tmax) = _parse_range($maybe1);
        if (defined $tmin) {
            $range = shift @parts;
            $needs_str = shift @parts;
        } else {
            $label = lc(shift @parts || 'main');
            $label =~ s/[^a-z0-9_]+/_/g;
            $label = substr($label, 0, 12);
            $range = shift @parts;
            $needs_str = shift @parts;
        }

        my $note = _norm_note(join(' ', @parts));
        my ($minl, $maxl) = _parse_range($range);

        if (!defined $minl || !defined $maxl) {
            _say($client, "Usage:");
            _say($client, "  ?lfm <min>-<max> need:healer,tank note");
            _say($client, "  ?lfm <label> <min>-<max> need:healer=1,tank=1,dps=2 note");
            return 1;
        }

        my $needs = _parse_needs_counts($needs_str // '');
        my $needs_label = _needs_to_label($needs);
        if ($needs_label eq '') {
            _say($client, "LFM needs required. Examples:");
            _say($client, "  need:healer,tank");
            _say($client, "  need:healer=1,tank=1,dps=2");
            return 1;
        }

        my %payload = (
            name        => $me_name,
            cid         => $cid,
            lvl         => _level($client),
            min         => $minl,
            max         => $maxl,
            needs_total => $needs,
            needs_rem   => { %$needs },
            note        => $note,
            label       => $label,
            zone        => $client->GetZoneID(),
            ts          => _now(),
        );

        _set_bucket(_key_lfm($cid, $label), encode_json(\%payload), $TTL_SECONDS);
        _idx_add_unique(_key_lfm_index(), "$cid:$label");

        _say($client, "LFM [$label] posted: $minl-$maxl $needs_label - $note");
        return 1;
    }

    return 0;
}

# ============================================================
# Public: call from EVENT_GROUP_CHANGE / EVENT_ZONE / EVENT_ENTERZONE
# ============================================================

sub lfg_try_pending_port {
    my ($client) = @_;
    return if !$client;

    my $me_name = _client_name($client);
    return if $me_name eq '';

    my $pend_key = _key_pend_name($me_name);
    my $raw = _get_bucket($pend_key);
    return if !defined $raw || $raw eq '';

    my $snap = _safe_decode($raw);
    return if !$snap || ref($snap) ne 'HASH';

    if (defined $snap->{ts} && (_now() - ($snap->{ts} || 0)) > $PEND_MAX_AGE_SECONDS) {
        _del_bucket($pend_key);
        return;
    }

    my $cid = _char_id($client);
    my $cons = _get_bucket(_key_consent($cid));
    if (defined $cons && $cons eq "0") {
        _del_bucket($pend_key);
        return;
    }

    my $g = $client->GetGroup();
    return if !$g;
	
    # HARD LOCK (cross-zone safe):
    # Only auto-port if current group leader name matches snapshot leader_name.
    # But don't delete pending just because we can't resolve leader entity cross-zone.

    my $leader_name_now = "";

    # Prefer a pure-name API if the server has it
    eval { $leader_name_now = $g->GetLeaderName(); 1; };

    # Fallback to entity leader (only works same-zone on many builds)
    if (!$leader_name_now || $leader_name_now eq "") {
        my $leader = $g->GetLeader();
        $leader_name_now = eval { $leader->GetName() } || "" if $leader;
    }

    my $leader_name_snap = lc($snap->{leader_name} // "");

    # If we still can't resolve leader name (likely cross-zone), just retry later
    if (!$leader_name_now || $leader_name_now eq "") {
        return; # keep pending; don't delete
    }

    if (lc($leader_name_now) ne $leader_name_snap) {
        _say($client, "Auto-port canceled: pending invite was for '$snap->{leader_name}', "
                    . "but your current group leader is '$leader_name_now'.");
        _del_bucket($pend_key);
        return;
    }


    my $zone_id = $snap->{zone_id};
    return if !$zone_id;

    if ($ZONE_BLACKLIST{$zone_id}) {
        _del_bucket($pend_key);
        return;
    }

    if (!$ALLOW_CROSS_ZONE_PORT) {
        if ($client->GetZoneID() != $zone_id) {
            _say($client, "Auto-port is disabled across zones. Ask leader to meet up.");
            return;
        }
    }

    # Capture invitee roles BEFORE LFG cleanup (for LFM decrement)
    my $invitee_roles = $snap->{invitee_roles};
    my $invitee_sel   = $snap->{invitee_role_sel} // '';
    my $invitee_primary = $snap->{invitee_role_primary} // '';

    if (ref($invitee_roles) ne 'ARRAY') {
        # fallback from LFG listing if snapshot missing
        my $pre_lfg_raw = _get_bucket(_key_lfg($cid));
        if (defined $pre_lfg_raw && $pre_lfg_raw ne '') {
            my $pre = _safe_decode($pre_lfg_raw);
            if ($pre && ref($pre) eq 'HASH') {
                $invitee_roles   = $pre->{roles} if ref($pre->{roles}) eq 'ARRAY';
                $invitee_primary = $pre->{role_primary} if defined $pre->{role_primary};
            }
        }
        $invitee_roles = [] if ref($invitee_roles) ne 'ARRAY';
    }

    # Port
    $client->MovePC($zone_id, $snap->{x}, $snap->{y}, $snap->{z}, $snap->{h});

    # Cleanup LFG
    _del_bucket(_key_lfg($cid));
    _idx_remove_value(_key_lfg_index(), $cid);

    # LFM decrement + cleanup
    my $leader_cid = $snap->{leader_cid};
    my $label      = lc($snap->{lfm_label} // 'main');

    my $lfm_key = _key_lfm($leader_cid, $label);
    my $lfm_raw = _get_bucket($lfm_key);
    if (defined $lfm_raw && $lfm_raw ne '') {
        my $lfm = _safe_decode($lfm_raw);
        if ($lfm && ref($lfm) eq 'HASH') {
            my $rem = $lfm->{needs_rem};

            if (ref($rem) eq 'HASH') {
                # Best-fit decrement
                _decrement_need_best($rem, $invitee_sel, $invitee_roles);

                if (_needs_all_filled($rem)) {
                    _del_bucket($lfm_key);
                    _idx_remove_value(_key_lfm_index(), "$leader_cid:$label");
                } else {
                    $lfm->{needs_rem} = $rem;
                    _set_bucket($lfm_key, encode_json($lfm), $TTL_SECONDS);
                }
            }
        }
    }

    _del_bucket($pend_key);
    _say($client, "You have been transported to your group leader.");
}

# ============================================================
# Internal: Invite + pending snapshot
# ============================================================

sub _invite_and_mark_pending {
    my ($leader_client, $target_name) = @_;
    return if !$leader_client;

    my $leader_cid = _char_id($leader_client);
    my $target_lc  = lc($target_name // "");

    # Invite cooldown
    my $cd_key = _key_cd_inv($leader_cid, $target_lc);
    my $cd = _get_bucket($cd_key);
    if (defined $cd && $cd ne '') {
        _say($leader_client, "Invite cooldown active for $target_name. Try again in a moment.");
        return;
    }
    _set_bucket($cd_key, "1", $INVITE_COOLDOWN_SECONDS);

    # If grouped, must be leader; if solo, fine (invite creates group)
    my $g = $leader_client->GetGroup();
    if ($g && !_is_leader($leader_client)) {
        _say($leader_client, "Only the GROUP LEADER can invite while grouped.");
        return;
    }

    # Must target someone who is LFG-listed (so we can enforce ranges + roles)
    my $target_info = _find_lfg_by_name_in_index($target_name);
    if (!$target_info) {
        _say($leader_client, "That player is not listed as LFG (or listing expired).");
        return;
    }

    # Range enforcement: leader must fit target's LFG range
    my $leader_lvl = _level($leader_client);
    my $tmin = $target_info->{min} // 1;
    my $tmax = $target_info->{max} // 255;
    if ($leader_lvl < $tmin || $leader_lvl > $tmax) {
        _say($leader_client, "Level-range check failed: you (lvl $leader_lvl) are outside $target_name's LFG range [$tmin-$tmax].");
        return;
    }

    # Pull leader's LFM main (if present) for best-fit role selection
    my $lfm_label = 'main';
    my $best_role = $target_info->{role_primary} // 'dps';
    my $needs_txt = '';

    my $lfm_raw = _get_bucket(_key_lfm($leader_cid, $lfm_label));
    if (defined $lfm_raw && $lfm_raw ne '') {
        my $lfm = _safe_decode($lfm_raw);
        if ($lfm && ref($lfm) eq 'HASH') {
            my $rem = $lfm->{needs_rem};
            $needs_txt = _needs_to_label($rem) if ref($rem) eq 'HASH';

            my $roles = $target_info->{roles};
            $roles = [$best_role] if ref($roles) ne 'ARRAY';
            $best_role = _best_role_for_needs($roles, $rem);
        }
    }

    # Pending collision: don't overwrite another leader's pending (unless stale)
    my $pend_key = _key_pend_name($target_name);
    my $existing_raw = _get_bucket($pend_key);
    if (defined $existing_raw && $existing_raw ne '') {
        my $ex = _safe_decode($existing_raw);
        if ($ex && ref($ex) eq 'HASH') {
            my $ex_leader = $ex->{leader_cid} // 0;
            my $ex_ts     = $ex->{ts} // 0;
            if ($ex_leader && $ex_leader != $leader_cid && (_now() - $ex_ts) < $PEND_MAX_AGE_SECONDS) {
                _say($leader_client, "That player already has a pending invite from another leader. Try again later.");
                return;
            }
        }
    }

    my $roles_all = $target_info->{roles};
    $roles_all = [$target_info->{role_primary}] if ref($roles_all) ne 'ARRAY';

    my %snap = (
        leader_name         => _client_name($leader_client),
        leader_cid          => $leader_cid,
        lfm_label           => $lfm_label,
        invitee_role_primary=> ($target_info->{role_primary} // 'dps'),
        invitee_roles       => $roles_all,
        invitee_role_sel    => $best_role,            # <-- BEST-FIT ROLE HERE
        zone_id             => $leader_client->GetZoneID(),
        x                   => $leader_client->GetX(),
        y                   => $leader_client->GetY(),
        z                   => $leader_client->GetZ(),
        h                   => $leader_client->GetHeading(),
        ts                  => _now(),
    );

    _set_bucket($pend_key, encode_json(\%snap), $PEND_TTL_SECONDS);
	
	# Notify invitee: invite incoming (cross-zone inbox)
	my $leader_name = _client_name($leader_client);
	my $note = "Invite incoming from $leader_name. Watch for a /invite popup. "
			 . "If you accept, you'll auto-port to them. "
			 . "If you don't want this, type ?lfg cancel.";

	_inbox_push_name($target_name, $leader_name, $note);


    # UX: show best-fit info to leader + requested invite helper
    my $cmd = "/invite $target_name";
    my $lnk = _link($cmd, "Type /invite $target_name");

    my $extra = "";
    $extra = " (best fit: $best_role" . ($needs_txt ? ", $needs_txt" : "") . ")" if $best_role;

    _say($leader_client, "Click: [$lnk]  (when they accept, they will auto-port)$extra");
}

# ============================================================
# Listing output
# ============================================================

sub _list_ads {
    my ($client, $which) = @_;
    return if !$client;

    my $me_lvl = _level($client);
    _say($client, "---- $which listings (filtered to your level $me_lvl) ----");

    my $shown = 0;

    if ($which eq 'LFG') {
        my $idx = _load_index(_key_lfg_index());
        my $pruned = _idx_prune_missing_lfg($idx);
        _save_index(_key_lfg_index(), $pruned) if @$pruned != @$idx;

        foreach my $cid (@$pruned) {
            my $raw = _get_bucket(_key_lfg($cid));
            next if !defined $raw || $raw eq '';
            my $p = _safe_decode($raw);
            next if !$p || ref($p) ne 'HASH';

            next if $me_lvl < ($p->{min} // 1) || $me_lvl > ($p->{max} // 255);

            my $name = $p->{name} // "Unknown";
            my $lvl  = $p->{lvl}  // "?";
            my $min  = $p->{min}  // "?";
            my $max  = $p->{max}  // "?";
            my $role = $p->{role_primary} // "dps";
            my $note = $p->{note} // "";

            my $line = "$name (lvl $lvl) [$min-$max] $role - $note";

            if (lc($name) ne lc(_client_name($client))) {
                my $inv = _link("?lfg invite $name", "Invite");
                my $tel = _link("?lfg tell $name", "Tell");
                $line .= "  [$inv] [$tel]";
                $line .= " (leader-only if grouped)" if ($client->GetGroup() && !_is_leader($client));
            }

            _say($client, $line);
            $shown++;
            last if $shown >= $LIST_MAX_SHOW;
        }
    }
    else { # LFM
        my $idx = _load_index(_key_lfm_index());
        my $pruned = _idx_prune_missing_lfm($idx);
        _save_index(_key_lfm_index(), $pruned) if @$pruned != @$idx;

        foreach my $token (@$pruned) {
            my ($cid, $label) = split(/:/, $token, 2);
            next if !$cid || !$label;

            my $raw = _get_bucket(_key_lfm($cid, $label));
            next if !defined $raw || $raw eq '';
            my $p = _safe_decode($raw);
            next if !$p || ref($p) ne 'HASH';

            next if $me_lvl < ($p->{min} // 1) || $me_lvl > ($p->{max} // 255);

            my $name = $p->{name} // "Unknown";
            my $lvl  = $p->{lvl}  // "?";
            my $min  = $p->{min}  // "?";
            my $max  = $p->{max}  // "?";
            my $note = $p->{note} // "";

            my $rem = $p->{needs_rem};
            my $needs_txt = _needs_to_label($rem);
            $needs_txt = "need:?" if $needs_txt eq '';

            my $tel = _link("?lfm tell $name", "Tell");
            my $line = "$name (lvl $lvl) [$min-$max] [$label] $needs_txt - $note  [$tel]";

            _say($client, $line);
            $shown++;
            last if $shown >= $LIST_MAX_SHOW;
        }
    }

    _say($client, "---- end ($shown shown) ----");
}

1;
