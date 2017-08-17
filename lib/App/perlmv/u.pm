package App::perlmv::u;

# DATE
# VERSION

use strict;
use warnings;
use Log::ger;

our %SPEC;

# for now we're not using a proper RM, we just record undo actions in
# ~/.perlmv-u.undo.dat

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Rename files using Perl code, with undo/redo',
};

sub _undo_file_path {
    $ENV{HOME} . "/.perlmv-u.undo.dat";
}

sub _read_undo_file {
    require Sereal::Decoder;
    my $path = _undo_file_path();
    if (-e $path) {
        local $/;
        open my $fh, "<", $path
            or die "perlmv-u: Can't open undo file '$path': $!\n";
        my $content = <$fh>;
        close $fh;
        return Sereal::Decoder::decode_sereal($content);
    } else {
        return [];
    }
}

sub _write_undo_file {
    require Sereal::Encoder;

    my $path = _undo_file_path();
    open my $fh, ">", $path
        or die "perlmv-u: Can't open undo file '$path' for writing: $!\n";
    print $fh Sereal::Encoder::encode_sereal($_[0]);
    close $fh or die "perlmv-u: Can't write undo file '$path': $!\n";
}

$SPEC{move_multiple} = {
    v => 1.1,
    args => {
        file_pairs => {
            summary => 'Pairs of [source, target]',
            schema => ['array*', {
                of=>['array*', elems=>['pathname*', 'pathname*']],
            }],
            req => 1,
            pos => 0,
            greedy => 1,
            description => <<'_',

Both `source` and `target` must be absolute paths.

_
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
        dry_run => 1,
    },
};
sub move_multiple {
    require File::MoreUtil;

    my %args = @_;

    my $tx_action = $args{-tx_action};
    if ($tx_action eq 'check_state') {
        my (%src, %dest, %exists);
        for my $pair (@{ $args{pairs} }) {
            my ($src, $dest) = @$pair;
            $src {$src}++;
            $dest{$dest}++;
            for my $k ($src, $dest) {
                unless (exists $exists{$k}) {
                    $exists{$k} = File::MoreUtil::file_exists($k);
                }
            }
        }
        my $all_dest_exist = 1;
        for (keys %dest) {
            unless ($exists{$_}) { $all_dest_exist = 0; last }
        }
        my $all_src_not_in_dest_not_exist = 1;
        for (keys %src) {
            next if $dest{$_};
            if ($exists{$_}) { $all_src_not_in_dest_not_exist = 0; last }
        }
        if ($all_dest_exist && $all_src_not_in_dest_not_exist) {
            # fixed
            return [304, "All sources do not exist and ".
                        "all targets already exist"];
        }
        my $all_src_exist = 1;
        for (keys %src) {
            unless ($exists{$_}) { $all_src_exist = 0; last }
        }
        my $all_dest_not_in_src_not_exist = 1;
        for (keys %dest) {
            next if $src{$_};
            if ($exists{$_}) { $all_dest_not_in_src_not_exist = 0; last }
        }
        if ($all_src_exist && $all_dest_not_in_src_not_exist) {
            # fixable
            my @do_actions;
            my @undo_actions;
            my @pairs;
            for my $pair (reverse @{ $args{pairs} }) {
                push @pairs, [$pair->[1] => $pair->[0]];
            }
            push @do_actions  , ['move_multiple', {pairs => $args{pairs}}];
            push @undo_actions, ['move_multiple', {pairs => \@pairs}];
            return [200, "OK", undef, {
                do_actions  =>\@do_actions,
                undo_actions=>\@undo_actions}];
        } else {
            # not fixable
            return [412, "Either some sources do not exist or ".
                        "some targets exist already"];
        }
    } elsif ($tx_action eq 'fix_state') {
        for my $pair (@{ $args{pairs} }) {
            my ($src, $dest) = @$pair;
            log_info("Renaming %s -> %s ...", $src, $dest);
            unless (rename $src, $dest) {
                if ($args{_ignore_errors}) {
                    warn "Can't rename '$src' -> '$dest': $!, skipped\n" if $!;
                } else {
                    return [500, "Can't rename '$src' -> '$dest': $!"] if $!;
                }
            }
        }
        [200, "OK"];
    } else {
        return [400, "Invalid -tx_action"];
    }
}

$SPEC{perlmv} = {
    v => 1.1,
    summary => 'Rename files using Perl code, with undo/redo',
    args => {
        eval => {
            summary => 'Perl code to rename file',
            schema => 'str*',
            cmdline_aliases => {e=>{}},
            description => <<'_',

Your Perl code will receive the original filename in `$_` and is expected to
modify it. If it is unmodified, the last expression is used as the new filename.
If it is also the same as the original filename, the file is not renamed.

_
            req => 1,
        },
        files => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'file',
            schema => ['array*', of=>'pathname*'],
            req => 1,
            pos => 0,
            greedy => 1,
        },
        d => {
            summary => 'Alias for --dry-run',
            schema => ['bool*', is=>1],
        },
    },
    features => {
        dry_run => 1,
    },
};
sub perlmv {
    require Cwd;
    require File::MoreUtil;
    require String::Elide::FromArray;

    my %args = @_;

    my $dry_run = $args{d} || $args{-dry_run};

    my @pairs;
    my $compiled_code;
    my %exists;
    for my $file (@{ $args{files} }) {
        my $absfile = Cwd::abs_path($file);
        if (!defined($absfile) ||
                !File::MoreUtil::file_exists($absfile)) {
            return [412, "File '$file' does not exist"];
        }
        unless ($compiled_code) {
            $compiled_code = eval "sub { $args{eval} }";
            die "Can't compile '$args{eval}': $@" if $@;
        }
        my $new;
        {
            my $orig = $file;
            local $_ = $file;
            my $ret = $compiled_code->();
            $new = $_ eq $orig && defined $ret ? $ret : $_;
            $new = $orig unless defined $new;
        }
        my $absnew0 = Cwd::abs_path($new);
        if (!defined($absnew0)) {
            return [412, "Can't rename '$file' to '$absnew0': ".
                        "path does not exist"];
        }
        if ($absnew0 eq $absfile) {
            next;
        }
        my $absnew;
        my $i = 0;
        while (1) {
            $absnew = $absnew0 . ($i ? ".$i" : "");
            last unless File::MoreUtil::file_exists($absnew) ||
                $exists{$absnew};
            $i++;
        }
        $exists{$absnew}++;
        push @pairs, [$absfile, $absnew];
    }

    if ($dry_run) {
        for my $pair (@pairs) {
            log_info("[DRY-RUN] Renaming %s -> %s ...", $pair->[0], $pair->[1]);
        }
        return [200, "OK (dry-run)"];
    }

    my $undo = _read_undo_file();
    my $res = move_multiple(pairs => \@pairs, -tx_action => 'check_state');
    return $res unless $res->[0] == 200;
    unshift @$undo, {
        time => time(),
        summary => "Rename ".scalar(@pairs)." file(s): ".
            String::Elide::FromArray::elide(
                [map { my $n = $_->[0]; $n =~ s!.+/!!; $n } @pairs], 70,
                {max_items => 7}),
        do_actions   => $res->[3]{'do_actions'},
        undo_actions => $res->[3]{'undo_actions'},
        status => 'done',
    };
    _write_undo_file($undo);
    move_multiple(pairs => \@pairs, -tx_action => 'fix_state');
}

$SPEC{undo} = {
    v => 1.1,
    summary => 'Undo last action',
    args => {
        ignore_errors => {
            schema => 'bool*',
        },
    },
};
sub undo {
    my %args = @_;

    my $undo = _read_undo_file();
    my $index;
    for my $i (0..$#{$undo}) {
        if ($undo->[$i]{status} eq 'done') {
            $index = $i;
            last;
        }
    }
    unless (defined $index) {
        return [412, "No action to undo".
                    (!@$undo ? " (undo history is empty)" :
                     " (all actions have been undone)")
            ];
    }

    # sanity check: we can only handle undo_action as a single call to
    # move_multiple
    my $actions = $undo->[$index]{undo_actions};
    @$actions == 1 && $actions->[0][0] eq 'move_multiple' or
        return [412, "Can't undo (index=$index, ERR_ID=1)"];

    my $res = move_multiple(
        %{$actions->[0][1]}, -tx_action=>'fix_state',
        (_ignore_errors => 1) x !!$args{ignore_errors},
    );
    return $res unless $res->[0] == 200;

    $undo->[$index]{status} = 'undone';
    _write_undo_file($undo);
    [200, "OK"];
}

$SPEC{redo} = {
    v => 1.1,
    summary => 'Redo last undone action',
};
sub redo {
    my %args = @_;

    my $undo = _read_undo_file();
    my $index;
    for my $i (0..$#{$undo}) {
        if ($undo->[$i]{status} eq 'undone') {
            $index = $i;
            last;
        }
    }
    unless (defined $index) {
        return [412, "No action to redo".
                    (!@$undo ? " (undo history is empty)" :
                     " (all actions have been redone)")
            ];
    }

    # sanity check: we can only handle undo_action as a single call to
    # move_multiple
    my $actions = $undo->[$index]{do_actions};
    @$actions == 1 && $actions->[0][0] eq 'move_multiple' or
        return [412, "Can't undo (index=$index, ERR_ID=1)"];

    my $res = move_multiple(%{$actions->[0][1]}, -tx_action=>'fix_state');
    return $res unless $res->[0] == 200;

    $undo->[$index]{status} = 'done';
    _write_undo_file($undo);
    [200, "OK"];
}

$SPEC{history} = {
    v => 1.1,
    summary => 'Show undo history',
};
sub history {
    require POSIX;

    my %args = @_;

    my $undo = _read_undo_file();
    my $resmeta = {'table.fields' => [qw/time summary status/]};
    my @res;
    for (@$undo) {
        push @res, {
            time => POSIX::strftime("%Y-%m-%dT%H:%M:%S", localtime $_->{time}),
            summary => $_->{summary},
            status => $_->{status},
        };
    }
    [200, "OK", \@res, $resmeta];
}

$SPEC{clear_history} = {
    v => 1.1,
    summary => 'Clear undo history',
};
sub clear_history {
    require POSIX;

    my %args = @_;

    unlink _undo_file_path();
    [200, "OK"];
}

1;
# ABSTRACT:

=head1 DESCRIPTION

See included script L<perlmv-u>.


=head1 SEE ALSO

L<App::perlmv>
