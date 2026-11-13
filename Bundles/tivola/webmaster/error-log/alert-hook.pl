#!/usr/bin/perl
# Installs a Lingo error catcher in Webmaster's scripts cast
# (Data/Casts Sander/HD/scripts.cxt): the game's own startup handler,
# globalInitialize, is made to end by turning a Lingo script's text into a
# parent script member and setting Director's alertHook to an instance of
# it, so every Lingo error (and alert) goes through it.
#
#   perl alert-hook.pl <scripts.cxt> <hook.lingo>
#
# The cast is changed in place. One already patched is left alone.
#
# A Director 7 cast is a big-endian RIFX file: an imap points to the mmap,
# which lists each chunk's fourCC, length and offset. A chunk is changed by
# appending its new copy and pointing its mmap entry there. The names are
# the Lnam chunk; each script is an Lscr chunk, its handlers 42-byte records
# pointing to their bytecode, its literals 8-byte records (type, offset)
# into its literal data.
use strict;
use warnings;

my ($path, $hook_path) = @ARGV;
die "usage: alert-hook.pl <scripts.cxt> <hook.lingo>\n" unless defined $hook_path;

sub slurp {
    my ($file) = @_;
    open(my $in, '<:raw', $file) or die "can't read $file: $!\n";
    local $/;
    my $data = <$in>;
    close($in);
    return $data;
}

my $data = slurp($path);
die "$path isn't a big-endian Director file (RIFX)\n" unless substr($data, 0, 4) eq 'RIFX';
die "$path has no imap where one should be\n" unless substr($data, 12, 4) eq 'imap';

sub u16 { unpack('n', substr($_[0], $_[1], 2)) }
sub u32 { unpack('N', substr($_[0], $_[1], 4)) }
sub put16 { substr($_[0], $_[1], 2) = pack('n', $_[2]) }
sub put32 { substr($_[0], $_[1], 4) = pack('N', $_[2]) }

# ---- the chunk map
my $mmap = u32($data, 24);
die "$path has no mmap where its imap says\n" unless substr($data, $mmap, 4) eq 'mmap';
my $map = $mmap + 8;
my ($header_length, $entry_length) = (u16($data, $map), u16($data, $map + 2));
my $used = u32($data, $map + 8);
my @entries;  # [fourCC, length, offset, where the entry is]
for my $i (0 .. $used - 1) {
    my $at = $map + $header_length + $i * $entry_length;
    push @entries, [substr($data, $at, 4), u32($data, $at + 4), u32($data, $at + 8), $at];
}

sub chunk {
    my ($i) = @_;
    my ($fourcc, $length, $offset) = @{$entries[$i]};
    die "chunk $i isn't the $fourcc its map says\n" unless substr($data, $offset, 4) eq $fourcc;
    return substr($data, $offset + 8, $length);
}

sub find { my ($fourcc) = @_; grep { $entries[$_][0] eq $fourcc } 0 .. $#entries }

sub replace {
    my ($i, $payload) = @_;
    $data .= "\0" if length($data) % 2;
    my $offset = length($data);
    $data .= $entries[$i][0] . pack('N', length($payload)) . $payload;
    $data .= "\0" if length($payload) % 2;
    put32($data, $entries[$i][3] + 4, length($payload));
    put32($data, $entries[$i][3] + 8, $offset);
    @{$entries[$i]}[1, 2] = (length($payload), $offset);
    put32($data, 4, length($data) - 8);
}

# ---- names
my ($lnam_index) = find('Lnam');
die "$path has no names table (Lnam)\n" unless defined $lnam_index;
my $lnam = chunk($lnam_index);
my @names;
{
    my $at = u16($lnam, 16);
    for (1 .. u16($lnam, 18)) {
        my $length = ord(substr($lnam, $at, 1));
        push @names, substr($lnam, $at + 1, $length);
        $at += 1 + $length;
    }
}
if (grep { $_ eq 'gSCHookText' } @names) {
    print "$path has its error catcher already\n";
    exit 0;
}
sub name_id {
    my ($name) = @_;
    for my $i (0 .. $#names) { return $i if $names[$i] eq $name }
    push @names, $name;
    $lnam .= chr(length($name)) . $name;
    return $#names;
}
my $name_do = name_id('do');
my $name_text = name_id('gSCHookText');
put32($lnam, 8, length($lnam) - 20);
put32($lnam, 12, length($lnam) - 20);
put16($lnam, 18, scalar @names);
replace($lnam_index, $lnam);

# ---- the movie script whose first handler is globalInitialize
my ($script_index, $script);
for my $i (find('Lscr')) {
    my $candidate = chunk($i);
    next unless u16($candidate, 72) > 0;
    my $first = unpack('s>', substr($candidate, u32($candidate, 74), 2));
    if ($first >= 0 && ($names[$first] // '') eq 'globalInitialize') {
        ($script_index, $script) = ($i, $candidate);
    }
}
die "$path has no script starting with globalInitialize\n" unless defined $script_index;

my ($handlers_count, $handlers_offset) = (u16($script, 72), u32($script, 74));
my ($literal_count, $literal_offset) = (u16($script, 78), u32($script, 80));
my ($literal_data_length, $literal_data_offset) = (u32($script, 84), u32($script, 88));

# The hook's text, and the lines do() runs to make it a member and set the hook.
my $hook = slurp($hook_path);
$hook =~ s/\r\n?/\n/g;
$hook =~ s/\n+\z//;
$hook =~ s/\n/\r/g;
my $install = join("\r",
    'global gSCHookText',
    'if not objectp(the alertHook) then',
    '  if the number of member "Second Chance alertHook" < 1 then',
    '    m = new(#script)',
    '    set the name of m to "Second Chance alertHook"',
    '    set the scriptType of m to #parent',
    '    set the scriptText of m to gSCHookText',
    '  end if',
    '  the alertHook = new(script "Second Chance alertHook")',
    'end if',
    'gSCHookText = 0');

my $literals = substr($script, $literal_offset, 8 * $literal_count);
my $literal_data = substr($script, $literal_data_offset, $literal_data_length);
my @added;
for my $text ($hook, $install) {
    my $raw = $text . "\0";
    $literal_data .= "\0" if length($literal_data) % 2;
    $literals .= pack('NN', 1, length($literal_data));
    $literal_data .= pack('N', length($raw)) . $raw;
    push @added, length($literals) / 8 - 1;
}
$literal_data .= "\0" if length($literal_data) % 2;

# Bytecode: an operand over 255 takes the two-byte form (opcode + 0x40).
# A literal's operand is its offset in the table, 8 bytes an entry.
sub op {
    my ($code, $operand) = @_;
    return chr($code) unless defined $operand;
    return chr($code) . chr($operand) if $operand < 256;
    return chr($code + 0x40) . pack('n', $operand);
}
my ($PUSHCONS, $ARGLISTNORET, $EXTCALL, $SETGLOBAL, $RET) = (0x44, 0x42, 0x57, 0x4f, 0x01);

# globalInitialize, the first handler record, with the install before its ret.
my ($code_length, $code_offset) = (u32($script, $handlers_offset + 4), u32($script, $handlers_offset + 8));
my $code = substr($script, $code_offset, $code_length);
die "globalInitialize doesn't end in ret\n" unless ord(substr($code, -1)) == $RET;
$code = substr($code, 0, -1)
    . op($PUSHCONS, $added[0] * 8) . op($SETGLOBAL, $name_text)
    . op($PUSHCONS, $added[1] * 8) . op($ARGLISTNORET, 1) . op($EXTCALL, $name_do)
    . op($RET);

my $out = $script;
sub append {
    my ($blob) = @_;
    $out .= "\0" if length($out) % 2;
    my $at = length($out);
    $out .= $blob;
    return $at;
}
my $new_code = append($code);
my $records = substr($script, $handlers_offset, 42 * $handlers_count);
put32($records, 4, length($code));
put32($records, 8, $new_code);
my $new_records = append($records);
my $new_literals = append($literals);
my $new_literal_data = append($literal_data);
$out .= "\0" if length($out) % 2;

put32($out, 8, length($out));
put32($out, 12, length($out));
put32($out, 52, length($out));  # the handler vectors: none, at the end as before
put32($out, 74, $new_records);
put16($out, 78, length($literals) / 8);
put32($out, 80, $new_literals);
put32($out, 84, length($literal_data));
put32($out, 88, $new_literal_data);
replace($script_index, $out);

# Written beside it, then put in its place.
my $temporary = "$path.patching";
open(my $output, '>:raw', $temporary) or die "can't write $temporary: $!\n";
print $output $data or die "can't write $temporary: $!\n";
close($output) or die "can't write $temporary: $!\n";
rename($temporary, $path) or die "can't replace $path: $!\n";
print "$path: error catcher installed\n";
