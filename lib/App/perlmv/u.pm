package App::perlmv::u;

# DATE
# VERSION

use strict;
use warnings;
use Log::ger;

our %SPEC;

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
}

$SPEC{perlmv} = {
    v => 1.1,
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
    },
    features => {
        dry_run => 1,
    },
};
sub perlmv {
    require Cwd;
    require File::MoreUtil;

    my %args = @_;

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
    [200, \@pairs];
}

1;
# ABSTRACT: Rename files using Perl code, with undo/redo

=head1 DESCRIPTION

See included script L<perlmv-u>.


=head1 SEE ALSO

L<App::perlmv>
