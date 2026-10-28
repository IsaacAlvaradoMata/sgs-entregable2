# Genera el diagrama en DBML (dbdiagram.io) a partir del script del modelo: perl docs/modelo/generar_dbml.pl < bd/02_modelo.sql > docs/modelo/sgs.dbml
use strict; use warnings;
my (%cols, @orden, %pk, %uk, @refs, %tnote, %cnote, %grupo, @grupos, $tabla, $seccion, %vistos);
my @lineas = <STDIN>;
for (my $i = 0; $i < @lineas; $i++) {
    my $l = $lineas[$i];
    if ($l =~ /^-- (\d+)\. (.+?)\s*$/ && !$tabla) { $seccion = $2; next; }
    if ($l =~ /^CREATE TABLE (\w+) \(/) { $tabla = $1; push @orden, $tabla; $grupo{$tabla} = $seccion;
        push @grupos, $seccion unless $vistos{$seccion}++; next; }
    if ($tabla && $l =~ /^\)/) { $tabla = undef; next; }
    if ($tabla) {
        if ($l =~ /CONSTRAINT \w+ PRIMARY KEY \((\w+)\)/) { $pk{$tabla}{$1} = 1; next; }
        if ($l =~ /CONSTRAINT \w+ UNIQUE \(([\w, ]+)\)/) { push @{$uk{$tabla}}, $1; next; }
        if ($l =~ /CONSTRAINT \w+ FOREIGN KEY \((\w+)\)/) { my $c = $1; my $sig = $lineas[$i+1];
            $sig =~ /REFERENCES (\w+) \((\w+)\)/ and push @refs, "Ref: $tabla.$c > $1.$2"; next; }
        next if $l =~ /^\s*(CONSTRAINT|--|AND|OR|\+|NVL2)/ || $l !~ /^\s+([A-Z][A-Z0-9_]*)\s+((?:NUMBER|VARCHAR2|DATE|TIMESTAMP)(?:\([\d, ]+\))?)(.*)$/;
        my ($c, $t, $resto) = ($1, $2, $3);
        my @at;
        push @at, 'not null' if $resto =~ /NOT NULL/;
        if ($resto =~ /DEFAULT (.+?)(?: NOT NULL)?,?\s*$/) { my $d = $1; $d =~ s/,$//;
            push @at, $d =~ /^'(.*)'$/ ? "default: '$1'" : $d =~ /^-?\d+(\.\d+)?$/ ? "default: $d" : "default: `$d`"; }
        push @{$cols{$tabla}}, [$c, lc $t, \@at];
        next;
    }
    if ($l =~ /^COMMENT ON TABLE (\w+) IS '(.*)';/) { $tnote{$1} = $2; next; }
    if ($l =~ /^COMMENT ON COLUMN (\w+)\.(\w+) IS '(.*)';/) { $cnote{$1}{$2} = $3; next; }
}
sub esc { my $s = shift; $s =~ s/''/'/g; $s =~ s/\\/\\\\/g; $s =~ s/'/\\'/g; return $s; }
print "// Sistema de Gestion de Supermercados (SGS) - modelo relacional generado de bd/02_modelo.sql\n";
print "Project SGS {\n  database_type: 'Oracle'\n  Note: 'Esquema SGS_ADMIN: 57 tablas en SGS_DATA y SGS_AUD, indices en SGS_IDX'\n}\n\n";
for my $t (@orden) {
    print "Table $t {\n";
    for my $c (@{$cols{$t}}) {
        my @at = @{$c->[2]};
        unshift @at, 'pk' if $pk{$t}{$c->[0]};
        @at = grep { $_ ne 'not null' } @at if $pk{$t}{$c->[0]};
        push @at, "note: '" . esc($cnote{$t}{$c->[0]}) . "'" if $cnote{$t}{$c->[0]};
        printf "  %s %s%s\n", $c->[0], $c->[1] =~ /\(/ ? "\"$c->[1]\"" : $c->[1], @at ? ' [' . join(', ', @at) . ']' : '';
    }
    if ($uk{$t}) { print "\n  indexes {\n"; for my $u (@{$uk{$t}}) { my @c = split /,\s*/, $u;
        print '    ', (@c > 1 ? '(' . join(', ', @c) . ')' : $c[0]), " [unique]\n"; } print "  }\n"; }
    print "\n  Note: '" . esc($tnote{$t}) . "'\n" if $tnote{$t};
    print "}\n\n";
}
print "$_\n" for @refs;
print "\n";
for my $g (@grupos) { my @ts = grep { $grupo{$_} eq $g } @orden; (my $n = $g) =~ s/[^A-Za-z0-9]+/_/g;
    print "TableGroup $n {\n", (map { "  $_\n" } @ts), "}\n\n"; }
