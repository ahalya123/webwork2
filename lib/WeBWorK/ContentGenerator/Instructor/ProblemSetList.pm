package WeBWorK::ContentGenerator::Instructor::ProblemSetList;
use base qw(WeBWorK::ContentGenerator::Instructor);

=head1 NAME

WeBWorK::ContentGenerator::Instructor::ProblemSetList - Entry point for Problem and Set editing

=cut

use strict;
use warnings;
use Apache::Constants qw(REDIRECT);
use CGI qw();
use WeBWorK::Utils qw(formatDateTime);

use constant PROBLEM_FIELDS =>[qw(source_file value max_attempts continuation)];

sub header {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $self->{ce};
	my $courseName = $ce->{courseName};
	my $root = $ce->{webworkURLs}->{root};
	
	if (defined $r->param('scoreSelected')) {
		$r->header_out(Location => "$root/$courseName/instructor/scoring?".$self->url_args);
		$self->{noContent} = 1;
		return REDIRECT;
	}
	$r->content_type("text/html");
	$r->send_http_header();
}

sub initialize {
	my $self = shift;
	my $r = $self->{r};
	my $db = $self->{db};
	my $ce = $self->{ce};
	my $authz = $self->{authz};
	my $courseName = $ce->{courseName};
	my $user = $r->param('user');
	
	unless ($authz->hasPermissions($user, "create_and_delete_problem_sets")) {
		$self->{submitError} = "You aren't authorized to create or delete problems";
		return;
	}
	
	if (defined($r->param('deleteSelected'))) {
		foreach my $wannaDelete ($r->param('selectedSet')) {
			$db->deleteGlobalSet($wannaDelete);
		}
	} elsif (defined($r->param('scoreSelected'))) {
		
	}elsif (   defined($r->param('makeNewSet'))   ) {
		my $newSetRecord = $db->{set}->{record}->new();
		my $newSetName = $r->param('newSetName');
		$newSetRecord->set_id($newSetName);
		$newSetRecord->set_header("");
		$newSetRecord->problem_header("");
		$newSetRecord->open_date("0");
		$newSetRecord->due_date("0");
		$newSetRecord->answer_date("0");
		eval {$db->addGlobalSet($newSetRecord)};
	} elsif (defined($r->param('importSet') )  )   {
		my $newSetRecord = $db->{set}->{record}->new();
		my $newSetName = $r->param('newSetName');
	##############################################
	# read data in set definition file
	# add the data to the set record
	##############################################
		my $set_definition_file = $r->param('set_definition_file');
		
		
		my ( $setName, $paperHeaderFile, $screenHeaderFile,
		     $openDate, $dueDate,  $answerDate,
		     $ra_problemData,    
		)    =    $self->readSetDef($set_definition_file);
		
		# Use the original name if form doesn't specify a new one.
		$newSetName = $setName unless $newSetName;
		
		# The set acquires the new name specified by the form.  A blank
		# entry on the form indicates that the imported set name will be used. 
		$newSetRecord->set_id($newSetName);
		$newSetRecord->set_header($screenHeaderFile);
		$newSetRecord->problem_header($paperHeaderFile);
		$newSetRecord->open_date($openDate);
		$newSetRecord->due_date($dueDate);
		$newSetRecord->answer_date($answerDate);
		
		#create the set
		eval {$db->addGlobalSet($newSetRecord)};
		die "addGlobalSet $newSetName in ProblemSetList:  $@" if $@;
		##############################################
		my @problemList = @{$ra_problemData};
		# add problems
		my $freeProblemID = WeBWorK::Utils::max($db->listGlobalProblems($newSetName)) + 1;
		foreach my $rh_problem (@problemList) {
			
			my $problemRecord = new WeBWorK::DB::Record::Problem;
			$problemRecord->problem_id($freeProblemID++);
			#warn "Adding problem $freeProblemID ", $rh_problem->source_file;
			$problemRecord->set_id($newSetName);
			$problemRecord->source_file($rh_problem->{source_file});
			$problemRecord->value($rh_problem->{value});
			$problemRecord->max_attempts($rh_problem->{max_attempts});
			# continuation flags???
			$db->addGlobalProblem($problemRecord);
			$self->assignProblemToAllSetUsers($problemRecord);  # handled by parent
		}
	
	} 
}

sub path {
	my ($self, $args) = @_;
	
	my $ce = $self->{ce};
	my $root = $ce->{webworkURLs}->{root};
	my $courseName = $ce->{courseName};
	return $self->pathMacro($args,
		"Home"          => "$root",
		$courseName     => "$root/$courseName",
		'instructor'    => "$root/$courseName/instructor",
		'sets'      => ''
	);
}

sub title {
	my $self = shift;
	return "Instructor Tools - Problem Set List for ".$self->{ce}->{courseName};
}

sub body {
	my $self = shift;
	my $r = $self->{r};
	my $db = $self->{db};
	my $ce = $self->{ce};
	my $authz = $self->{authz};
	my $root = $ce->{webworkURLs}->{root};
	my $courseName = $ce->{courseName};
	my $user = $r->param('user');
	my $key  = $r->param('key');
	my $effectiveUserName = $r->param('effectiveUser');
	my $URL = $r->uri;
	my $instructorBaseURL = "$root/$courseName/instructor";
	my $importURL = "$instructorBaseURL/problemSetImport/";
	my $sort = $r->param('sort') ? $r->param('sort') : "due_date";
	
	my @set_definition_files    = $self->read_dir($ce->{courseDirs}->{templates},'\\.def');
	return CGI::em("You are not authorized to access the instructor tools") unless $authz->hasPermissions($user, "access_instructor_tools");

	# Slurp each set record for this course in @sets
	# Gather data from the database
	my @users = $db->listUsers;
	my @set_IDs = $db->listGlobalSets;
	my @sets  = $db->getGlobalSets(@set_IDs);
	my %counts;
	my %problemCounts;
	
	$WeBWorK::timer2->continue("Begin obtaining problem info on sets") if defined $WeBWorK::timer2;
	foreach my $set_id (@set_IDs) {
		$problemCounts{$set_id} = scalar($db->listGlobalProblems($set_id));
	#	$counts{$set_id} = $db->listSetUsers($set_id);
	}
	$WeBWorK::timer2->continue("End obtaining problem on sets") if defined $WeBWorK::timer2;
	
	$WeBWorK::timer2->continue("Begin obtaining assigned user info on sets") if defined $WeBWorK::timer2;
	foreach my $set_id (@set_IDs) {
	#	$problemCounts{$set_id} = scalar($db->listGlobalProblems($set_id));
		$counts{$set_id} = $db->listSetUsers($set_id);
	}	
	$WeBWorK::timer2->continue("End obtaining assigned user info on sets") if defined $WeBWorK::timer2;

	# Sort @sets based on the sort parameter
	# Invalid sort types will just cause an unpredictable ordering, which is no big deal.
	@sets = sort {
		if ($sort eq "set_id") {
			return $a->$sort cmp $b->$sort;
		}elsif ($sort =~ /_date$/) {
			return $a->$sort <=> $b->$sort;
		} elsif ($sort eq "num_probs") {
			return $problemCounts{$a->set_id} <=> $problemCounts{$b->set_id};
		} elsif ($sort eq "num_students") {
			return $counts{$a->set_id} <=> $counts{$b->set_id};
		}
	} @sets;
	
	my $table = CGI::Tr({}, 
		CGI::th("Sel.")
		. CGI::th(CGI::a({"href"=>$URL."?".$self->url_authen_args."&sort=set_id"},       "ID"))
		. CGI::th(CGI::a({"href"=>$URL."?".$self->url_authen_args."&sort=open_date"},    "Open Date"))
		. CGI::th(CGI::a({"href"=>$URL."?".$self->url_authen_args."&sort=due_date"},     "Due Date"))
		. CGI::th(CGI::a({"href"=>$URL."?".$self->url_authen_args."&sort=answer_date"},  "Answer Date"))
		. CGI::th(CGI::a({"href"=>$URL."?".$self->url_authen_args."&sort=num_probs"},    "Num. Problems"))
		. CGI::th(CGI::a({"href"=>$URL."?".$self->url_authen_args."&sort=num_students"}, "Assigned to:"))
	) . "\n";
	
	foreach my $set (@sets) {
		my $count = $counts{$set->set_id};
		
		my $userCountMessage = $self->userCountMessage($count, scalar(@users));
	
		$table .= CGI::Tr({}, 
			CGI::td({}, 
				CGI::checkbox({
					"name"=>"selectedSet",
					"value"=>$set->set_id,
					"label"=>"",
					"checked"=>"0"
				})
			)
			. CGI::td({}, CGI::a({href=>$r->uri.$set->set_id."/?".$self->url_authen_args}, $set->set_id))
			. CGI::td({}, formatDateTime($set->open_date))
			. CGI::td({}, formatDateTime($set->due_date))
			. CGI::td({}, formatDateTime($set->answer_date))
			. CGI::td({}, CGI::a({href=>$r->uri.$set->set_id."/problems/?".$self->url_authen_args}, $problemCounts{$set->set_id}))
			. CGI::td({}, CGI::a({href=>$r->uri.$set->set_id."/users/?".$self->url_authen_args}, $userCountMessage))
		) . "\n"
	}
	$table = CGI::table({"border"=>"1"}, "\n".$table."\n");

	my $form = join("",
		CGI::start_form({"method"=>"POST", "action"=>$r->uri}),"\n", # This form is for deleting sets, and points to itself
		$table,"\n",
		CGI::br(),"\n",
		$self->hidden_authen_fields,"\n",
		CGI::submit({"name"=>"deleteSelected", "label"=>"Delete Selected"}),"\n",
		CGI::submit({"name"=>"scoreSelected", "label"=>"Score Selected"}),"\n",
		CGI::end_form(),"\n",
		CGI::start_form({"method"=>"POST", "action"=>$r->uri}),"\n",
		$self->hidden_authen_fields,"\n",
		"New Set Name: ",
		CGI::input({type=>"text", name=>"newSetName", value=>""}),
		CGI::submit({"name"=>"makeNewSet", "label"=>"Create"}),"\n",
		CGI::end_form(),"\n",
		CGI::start_form({"method"=>"POST", "action"=>$r->uri}),"\n",
		$self->hidden_authen_fields,"\n",
		CGI::submit({"name"=>"importSet", "label"=>"Import"}),"\n",
		CGI::popup_menu(-name=>'set_definition_file', 
				                 -values=>\@set_definition_files, 
		),' as set ',
		CGI::input({type=>"text", name=>"newSetName", value=>""}),
		CGI::end_form(),"\n"
	);
	print $form;
	
	return "";
}

##############################################################################################
#  Utility scripts -- may be moved to Utils.pm
##############################################################################################


sub readSetDef {
	my $self          = shift;
	my $fileName      = shift;
	my $templateDir   = $self->{ce}->{courseDirs}->{templates};
	my $filePath      = "$templateDir/$fileName";
    my $setNumber = '';
    if ($fileName =~ m|^set(\w+)\.def$|) {
    	$setNumber = $1;
    } else {
        warn qq{The setDefinition file name must begin with   <CODE>set</CODE>},
			 qq{and must end with   <CODE>.def</CODE>  . Every thing in between becomes the name of the set. },
			 qq{For example <CODE>set1.def</CODE>, <CODE>setExam.def</CODE>, and <CODE>setsample7.def</CODE> },
			 qq{define sets named <CODE>1</CODE>, <CODE>Exam</CODE>, and <CODE>sample7</CODE> respectively. },
			 qq{The filename, $fileName, you entered is not legal\n };

    }

    my ($line,$name,$value,$attemptLimit,$continueFlag);
	my $paperHeaderFile = '';
	my $screenHeaderFile = '';
	my ($dueDate,$openDate,$answerDate);
	my @problemData;	
    if ( open (SETFILENAME, "$filePath") )    {
	#####################################################################
	# Read and check set data
	#####################################################################
		while (<SETFILENAME>) {
			chomp($line = $_);
			$line =~ s|(#.*)||;                              ## don't read past comments
			unless ($line =~ /\S/) {next;}                   ## skip blank lines
			$line =~ s|\s*$||;                               ## trim trailing spaces
			$line =~ m|^\s*(\w+)\s*=\s*(.*)|;
			if ($1 eq 'setNumber') {
				next;
			} elsif ($1 eq 'paperHeaderFile') {
				$paperHeaderFile = $2;
			} elsif ($1 eq 'screenHeaderFile') {
				$screenHeaderFile = $2;
			} elsif ($1 eq 'dueDate') {
				$dueDate = $2;
			} elsif ($1 eq 'openDate') {
				$openDate = $2;
			} elsif ($1 eq 'answerDate') {
				$answerDate = $2;
			} elsif ($1 eq 'problemList') {
				last;
			} else {
				warn "readSetDef error, can't read the line: $line";
			}
		}
	#####################################################################
	# Check and format dates
	#####################################################################
		my ($time1,$time2,$time3) = map { $_ =~ s/\s*at\s*/ /; WeBWorK::Utils::parseDateTime($_);  }    ($openDate, $dueDate, $answerDate);
	
		unless ($time1 <= $time2 and $time2 <= $time3) {
			warn "The open date: $openDate, due date: $dueDate, and answer date: $answerDate must be defined and in chronologicasl order.";
		}
	# Check header file names
		$paperHeaderFile =~ s/(.*?)\s*$/$1/;   #remove trailing white space
		$screenHeaderFile =~ s/(.*?)\s*$/$1/;   #remove trailing white space
	
	 #   warn "setNumber: $setNumber\ndueDate: $dueDate\nopenDate: $openDate\nanswerDate: $answerDate\n";
	 #   warn "time1 $time1 time2 $time2 time3 $time3";
	#####################################################################
	# Read and check list of problems for the set
	#####################################################################

		while(<SETFILENAME>) {
			chomp($line=$_);
			$line =~ s/(#.*)//;                             ## don't read past comments
			unless ($line =~ /\S/) {next;}                  ## skip blank lines
	
			($name, $value, $attemptLimit, $continueFlag) = split (/\s*,\s*/,$line);
			#####################
			#  clean up problem values
			###########################
			$name =~ s/\s*//g;
			#                                 push(@problemList, $name);
			$value = "" unless defined($value);
			$value =~ s/[^\d\.]*//g;
			unless ($value =~ /\d+/) {$value = 1;}
			#                                 push(@problemValueList, $value);
			$attemptLimit = "" unless defined($attemptLimit);
			$attemptLimit =~ s/[^\d-]*//g;
			unless ($attemptLimit =~ /\d+/) {$attemptLimit = -1;}
			#                                 push(@problemAttemptLimitList, $attemptLimit);
			$continueFlag = "0" unless( defined($continueFlag) && @problemData );  
				# can't put continuation flag ont the first problem
			#                                 push(@problemContinuationFlagList, $continueFlag);
			push(@problemData, {source_file    => $name,
			                    value          =>  $value,
			                    max_attempts   =>, $attemptLimit,
			                    continuation   => $continueFlag 
			                    });
		}
		close(SETFILENAME);
		($setNumber,
		 $paperHeaderFile,
		 $screenHeaderFile,
		 $time1,
		 $time2,
		 $time3,
		 \@problemData,
		);
	} else {
		warn "Can't open file $filePath\n";
	}
}

1;
