#!/usr/bin/env perl
# CallSam: Call bases from a sequence alignment/map
# Author: Lee Katz <lkatz@cdc.gov>
# Run with no options for usage help

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use List::Util qw/sum min max/;
use Bio::Perl;
use File::Basename;
use FindBin;
use lib "$FindBin::Bin/../lib";
use CallSam qw/logmsg/;

$0=fileparse($0);
exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(help min-coverage=i min-frequency=s reference=s numcpus=i unsorted variants-only mpileupxopts=s debug));
  die usage($settings) if($$settings{help} || !@ARGV);
  $$settings{'min-coverage'}||=10;
  $$settings{'min-frequency'}||=0.75;
  $$settings{'reference'} || logmsg("Warning: reference not given");
  $$settings{numcpus}||=1;
  $$settings{mpileupxopts}||="-q 1";
  $$settings{tempdir}||="tmp";
  mkdir $$settings{tempdir} if(!-d $$settings{tempdir});
  my ($file)=@ARGV;
  die "ERROR: need input file\n".usage($settings) if(!$file);
  
  # get all the reference bases into a hash
  my $refBase=readReference($settings);
  printHeaders($settings);
  my $numpositions=bamToVcf($file,$refBase,$settings);

  logmsg "Done. $numpositions positions were analyzed.";

  return 0;
}

sub readReference{
  my($settings)=@_;
  my %seq;

  return \%seq if(!$$settings{reference});
  die "Could not locate the reference $$settings{reference}\n".usage($settings) if(!-f $$settings{reference});

  my $in=Bio::SeqIO->new(-file=>$$settings{reference});
  while(my $seq=$in->next_seq){
    # undef the zero position to make this 1-based
    $seq{$seq->id}=[undef,split(//,$seq->seq)];
  }
  return \%seq;
}

sub printHeaders{
  my($settings)=@_;
  my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
  my $date=sprintf("%04d%02d%02d",$year+1900,$mon+1,$mday);

  # simply put all the headers into an array to process later
  my @header=split/\s*\n+\s*/,qq(
      fileformat=VCFv4.2
      fileDate=$date
      source=$0
      INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
      INFO=<ID=AC,Number=1,Type=Integer,Description="allele count in genotypes, for each ALT allele, in the same order as listed">
  );
  push(@header,"reference=".$$settings{reference}) if($$settings{reference});
  
  # clean up and process the headers
  @header=grep(!/^\s*$/,@header);
  for(@header){
    $_='##'.$_;
  }
  # add the final header with one hash tag
  push(@header,join("\t",'#CHROM',qw(POS ID REF ALT QUAL FILTER INFO)));
  # finally print it out
  print $_."\n" for(@header);
  # return the number of headers
  return scalar(@header);
}
sub bamToVcf{
  my($file,$refBase,$settings)=@_;
  my $mpileup="$$settings{tempdir}/mpileup";

  # Run mpileup to show the pileup at each position.
  # Feed each line of mpileup to the threads that analyze them.
  my $fp;
  my $numPositions=0;
  my $refArg=($$settings{reference})?"-f $$settings{reference}":"";
  my $command="samtools mpileup $$settings{mpileupxopts} $refArg -O -s '$file'";
  logmsg "\n  $command";
  system("$command > $mpileup"); die if $?;

  logmsg "Mpileup done.  Reading the output $mpileup";
  open($fp,$mpileup) or die "Could not open mpileup $mpileup:$!";

  while(my $line=<$fp>){
    $numPositions++;
    pileupToVcf($line,$refBase,$settings);

    if($numPositions % 100000 == 0){
      logmsg "Finished with $numPositions positions";
      last if($$settings{debug} && $numPositions > 10000);
    }
  }
  logmsg "Closing the samtools/mpileup stream";
  close $fp;                                      # close out samtools
  logmsg "Finished with $numPositions positions";
  
  return $numPositions;
}

sub pileupToVcf{
  my($line,$refBase,$settings)=@_;
  my @bamField=qw(contig pos basecall depth dna qual mappingQual readPos);
  chomp $line;
  # %F and @F have all the mpileup fields.
  # These values will be parsed to make VCF output fields.
  my @F=split /\t/, $line;
  my %F;
  @F{@bamField}=@F;
  $F{info}={DP=>$F{depth}}; # put the depth into the info field so that it is displayed correctly.
  # Turn the DNA cigar line to an array.
  ($F{dnaArr},$F{dnaDirection})=parseDnaCigar(\%F,$refBase,$settings);
  # Use the DNA array and other %F fields to make a consensus base.
  my ($basecall,$passFail,$qual)=findConsensus(\%F,$settings);
  # Find the reference base in the complex hash. A dot if not found.
  my $ref=$$refBase{$F{contig}}[$F{pos}] || '.'; 
  # A samtools-style identifier for the appropriate VCF field.
  my $ID=$F{contig}.':'.$F{pos};
  # uppercase the calls to standardize it and make comparisons easier
  $ref=uc($ref);

  # Use the info hash to generate the VCF info field
  my $info="";
  while(my($key,$value)=each(%{$F{info}})){
    $info.="$key=$value;";
  } 
  # chop off that semicolon
  $info=~s/;$//;
  # I wonder if substr($info,0,-1) would be faster to remove the semicolon
  #$info=substr($info,0,-1);

  # if the user only wants variants and it is not a variant site, then skip it
  if( $$settings{'variants-only'} 
    && (uc($ref) eq uc($basecall) || uc($basecall) eq 'N' || uc($ref) eq 'N')
  ){
    next;
  }
  print join("\t",$F{contig},$F{pos},$ID,$ref,uc($basecall),$qual,$passFail,$info)."\n";
}

# finds the consensus for a position
sub findConsensus{
  my($F,$settings)=@_;
  # If passFail is set to _anything_ before the final base call is made, then it is considered a fail.
  # It is literally used in the filter field though and is informative in the VCF output
  my %passFail;
  # min depth requirement
  $passFail{depth}=$$F{depth} if($$F{depth} < $$settings{'min-coverage'});

  my $dna=$$F{dna};
  #my $dna=uc($$F{dna});

  # find counts
  my %nt;
  $nt{$_}=0 for(("A".."Z"),'*'); # start the counts at zero
  for (@{$$F{dnaArr}}){
    $nt{$_}++;
    #$nt{uc($_)}++;
  }

  # Sort the counts and find the majority
  my @majorityNt=sort {
    return $nt{$b}<=>$nt{$a}; 
  } keys(%nt);
  my $winner=$majorityNt[0];
  my $runnerUp=$winner; # in case $winner needs to be set to another thing

  # alter the hash to show the Allele Count
  $$F{info}{AC}=$nt{$winner};

  # Majority consensus requirement
  my $frequency=0.00;
    $frequency=sprintf("%0.2f",$nt{$winner}/$$F{depth}) if($$F{depth}>0);
  $passFail{freq}=$frequency if($frequency < $$settings{'min-frequency'});
  #delete($passFail{freq});

  # Forward and reverse reads requirement {dnaDirection}.
  # For each nucleotide that agrees with the winning nt,
  # see which direction its read is going in.
  my %dCount=(F=>0,R=>0); # direction counter
  for(my $i=0;$i<$$F{depth};$i++){
    my $nt=$$F{dnaArr}[$i];
    #print join("\t","$nt/$winner",$$F{dnaDirection}[$i])."\n";
    next if(uc($nt) ne uc($winner));
    my $direction=$$F{dnaDirection}[$i];
    $dCount{$$F{dnaDirection}[$i]}++;
  }
  my $sum=$dCount{F}+$dCount{R};
  if($sum > 0){ # sometimes forward/reverse is not specified and therefore cannot be used
    if($dCount{F}/$sum < 0.1 || $dCount{R}/$sum < 0.1){
      $passFail{forwardReads}=$dCount{F};
      $passFail{reverseReads}=$dCount{R};
    }
  }
  #die Dumper($$F{contig},$$F{pos},\%dCount,\%passFail,$$F{dnaArr})."\n" if($$F{pos}==10202 && $$F{contig} eq 'NODE56length16727cov16.9252');

  # Make some kind of score for the SNP
  # Currently: SUM(the quality score times the mapping quality)
  #   or subtract a particular base's score if it does not agree with the consensus
  my $score=0;
  my @qual=map(ord($_)-33,split(//,$$F{qual}));
  my @baq =map(ord($_)-33,split(//,$$F{mappingQual}));
  for(my $i=0;$i<$$F{depth};$i++){
    my $weight=$qual[$i]*$baq[$i];
    if(uc($$F{dnaArr}[$i]) eq uc($winner)){
      $score+=$weight;
    } else {
      $score-=$weight;
    }
  }
  # transform the score
  # TODO maybe put some rationale and thinking into this formula
  $score=sprintf("%0.2f",$score);
  #$score=sprintf("%0.2f",$score/sum(@qual,@baq));
  # If the score is too small, then the base call is ambiguous and doesn't pass the filter
  # TODO: test what the score theshold should be 
  if($score < 0){
    $passFail{score}=$score;
    $winner='N';
  }

  # set the pass/fail field correctly
  my $passFail="PASS";
  my @passFailKey=keys(%passFail);
  if(@passFailKey > 0){
    $passFail="";
    $passFail.="$_:$passFail{$_};" for(@passFailKey);
    $passFail.="ifIHadToGuess:$runnerUp"; # add this last key/value without semicolon
    $winner="N";
  }

  return ($winner,$passFail,$score);
}

# Turn a cigar string into a meaningful array of bases
sub parseDnaCigar{
  my($bamField,$refBase,$settings)=@_;
  my $cigar=$$bamField{dna};
  #$cigar=uc($cigar); 
  my @direction; # don't want 100% in one direction
  
  my $length=length($cigar);
  # Parse the cigar.
  # ^Xn is the start of a read with base quality with a nucleotide.
  # n$ is the end of the read with its nucleotide.
  # . is a match.
  # , is the reverse-strand match.
  my @base=();
  for(my $i=0;$i<$length;$i++){
    my $x=substr($cigar,$i,1);
    my $nt="";

    # If this is the beginning of a read,
    # then get the mapping quality and advance to the next nt.
    if($x eq '^'){
      $i++;
      my $mappingQuality=substr($cigar,$i,1);
      $i++;
      $x=substr($cigar,$i,1);
    } 
    
    # If this is the end of a read, 
    # then mark it and move on.
    if ($x eq '$'){
      my $startEnd=1;
      next;
    }

    # If this is an insertion, 
    # then the format is +Nn... where N is the number inserted
    # and n... is the nucleotide(s).
    if ($x eq '+'){
      $i++;
      die "Insertion shown in mpileup, but the length was not given" if(substr($cigar,$i,1)!~/(\d+)/);
      my $lengthOfInsertion=$1;
      my $digitsLen=length($lengthOfInsertion);

      $i+=$digitsLen; # advance to the actual insertion
      $x=substr($cigar,$i,$lengthOfInsertion); # the insertion
      $i+=$lengthOfInsertion; # advance past the insertion
    }
    # If this is a deletion, 
    # then the format is -Nn... where N is the number deleted
    # and n... is the nucleotide that was deleted
    elsif($x eq '-'){
      $i++;
      die "Deletion shown in mpileup, but the length was not given" if(substr($cigar,$i,1)!~/(\d+)/);
      my $lengthOfDeletion=$1;                   # how long the deletion is in the read
      my $digitsLen=length($lengthOfDeletion);   # how many digits that number takes up

      $i+=$digitsLen; # advance to the actual deletion
      $x='*' x $lengthOfDeletion; # the "nucleotide" is a number of asterisks in a row
      $i+=$lengthOfDeletion; # advance past the deletion
    }
    
    # If this is not the beginning or end of a read,
    # then grab the nt. This would also grab deletions.
    if ($x eq '.' || $x eq ','){
      my $pos=$$bamField{pos};
      my $contig=$$bamField{contig};
      $nt=uc($$refBase{$contig}[$pos]);
      $nt=lc($nt) if($x eq ','); # lowercase indicates reverse
      #die Dumper [$x,\@base,$bamField];
    } else {
      $nt=$x;
    }

    # Determine the directionality. Deletions are asterisks and will be in no direction.
    my $direction;
    if($nt=~/[a-z,]/){
      $direction='R';
    } elsif($nt=~/[A-Z\.]/){
      $direction='F';
    } elsif($nt=~/\*/){
      $direction="?";
    } else{
      # for some reason, a deletion followed by the start of the read is causing problems.  This is a band-aid.
      #warn "rewind!\n"; 
      $i-=2; next; 
      die "ERROR: the directionality could not be parsed from '$nt'\n".Dumper(bamField=>$bamField,nt=>join(" ",@base),direction=>join(" ",@direction));
    }
    push(@direction,$direction);

    push(@base,uc($nt)); # since the directionality is retained, then it is okay to forget lower/upper case for this nt
  }
  return \@base if(!wantarray);
  return (\@base,\@direction);
}

sub usage{
  my ($settings)=@_;
  my $usage="Creates a vcf from a sorted bam file.
  Usage: $0 file.sorted.bam > out.vcf
  --min-coverage 10 Min depth at a position
  --min-frequency 0.75 Min needed for majority
  --numcpus 1  WARNING: with multiple CPUs there will be race conditions, and so your output will need to be sorted (see examples below)
  #--unsorted Produces streaming output, but unsorted due to thread race conditions
  --variants-only Do not print invariant sites
  --noindels      Do not include indels. Indel sites become 'N'.
  -mpileup '-q 1' Send options to mpileup 'samtools mpileup' for additional help
  -h for more help
  ";
  
  return $usage if(!$$settings{help});
  $usage.="
  MORE HELP
  --reference reference.fasta (optional)
  --debug To call only the first 10k bases
  EXAMPLES
    $0 file.sorted.bam > out.vcf              # vanilla usage
    $0 file.sorted.bam | gzip -c > out.vcf.gz # compressed

    # sort the output in case you used multiple CPUs
    $0 file.sorted.bam > out.vcf && (grep '#' out.vcf; grep -v '#' out.vcf | sort -k1,1 -k2,2n) > out.sorted.vcf

  The score at a position is the sum of the quality scores in the reads at that particular position times the mapping quality of those reads. Negative score for a base that does not agree with the consensus.
  When there is an ambiguous base call though, there will be a field called ifIHadToGuess whose value is the best guess at that position.
  ";

  return $usage;
}
