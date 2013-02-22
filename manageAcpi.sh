#!/bin/sh
#############################################################################
# Script aimed at setting the NAS in sleep state whenever possible
# in order to save energy 
# - The script enables to define a curfew timeslot 
# - A timeslot where the NAS shall sleep if no other device
#   is online
# - A timeslot where the system shall never sleep 
#
# The script shall be launched at system startup 
#
# Usage: manageAcpi.sh [-p duration] [-w duration] [-a beg,end] [-c beg,end,acpi] [-n beg,end,acpi,delay,ips] [-vm] 
#
#	- p duration :		define the duration (in seconds) between each respective poll (by default: 120)
#	- w duration :		define the duration (in seconds) for which the NAS should never sleep after 
#				it wakes up (by default: 600) 
#	- a beg,end :		define a timeslot in which the NAS shall never go sleeping (e.g. because admin
#				tasks are scheduled during this slot
#				beg: time of the beginning of the slot (format: hh:mm)
#				end: time of the end of the slot (format: hh:mm)
#	- c beg,end,acpi :	define a timeslot in which the NAS shall always go sleeping (curfew)
#				beg: time of the beginning of the slot (format: hh:mm)
#				end: time of the end of the slot (format: hh:mm)
#				acpi: the ACPI state selected for the sleep (3 or 5) 
#	- n beg,end,acpi,delay,ips : define a timeslot in which the NAS shall sleep if none of the other devices are online
#				beg: time of the beginning of the slot (format: hh:mm)
#				end: time of the end of the slot (format: hh:mm)
#				acpi: the ACPI state selected for the sleep (3 or 5)
#				delay: delay in seconds between last device going offline and start of sleep 
#				ips: IP addresses of the devices to poll (at least one), separated by "+" (Note: IP shall be static)
#	- v:			Requests the log to be more verbose
#				Note: This is likely to prevent the disks to spin down 
#	- m:			Send mail on ACPI state change
#
# Author: fritz from NAS4Free forum
#
#############################################################################

# Initialization of the script name
readonly SCRIPT_NAME=`basename $0` 		# The name of this file

# set script path as working directory
cd "`dirname $0`"

# Import required scripts
. "config.sh"
. "common/commonLogFcts.sh"
. "common/commonMailFcts.sh"
. "common/commonLockFcts.sh"

# Initialization of the constants 
readonly START_TIMESTAMP=`$BIN_DATE +"%s"`
readonly LOGFILE="$CFG_LOG_FOLDER/$SCRIPT_NAME.log"
readonly ACPI_STATE_LOGFILE="$CFG_LOG_FOLDER/acpi.log"

# Set variables corresponding to the input parameters
ARGUMENTS="$@"

# Log verbosity (1: verbose, 0: less verbose)
I_VERBOSE=0

# 1: mail to be sent on ACPI state change, 0: otherwise 
I_MAIL_ACPI_CHANGE=0

# Initialisation of the default values for the arguments of the script
I_POLL_INTERVAL=120			# number of seconds to wait between to cycles

I_DELAY_PREVENT_SLEEP_AFTER_WAKE="600"	# Amount of time during which the NAS will never go to sleep after waking up

I_CHECK_ALWAYS_ON="0"			# 1 if the check shall be performed, 0 otherwise
I_BEG_ALWAYS_ON="00:00"			# time when the NAS shall never sleep (because of management tasks like backup may start)
I_END_ALWAYS_ON="00:00"			# If end = beg => 24 hours

I_CHECK_CURFEW_ACTIVE="0"			# 1 if the check shall be performed, 0 otherwise
I_BEG_POLL_CURFEW="00:00"			# time when the script enters the sleep state (except if tasks like backup are running)
I_END_POLL_CURFEW="00:00"			# If end = beg => 24 hours
I_ACPI_STATE_CURFEW="0"			# ACPI state 

I_CHECK_NOONLINE_ACTIVE="0"		# 1 if the check shall be performed, 0 otherwise
I_BEG_POLL_NOONLINE="0:00"		# time when the script starts to check wether there is no other device is online
I_END_POLL_NOONLINE="00:00"		# If end = beg => 24 hours 
I_ACPI_STATE_NOONLINE="0"			# ACPI state if no other device is online 
I_DELAY_NOONLINE="0"			# Delay in seconds between the moment where no devices are online anymore and the moment where the NAS shall sleep
I_IP_ADDRS="" 				# IP addresses of the devices to be polled, separated by a space character)

# Initialization the global variables
awake="0"				# 1=NAS is awake, 0=NAS is about to sleep (resp. just woke up)


##################################
# Check script input parameters
#
# Params: all parameters of the shell script
##################################
parseInputParams() {

	local regex_dur regex_hh regex_mm regex_time regex_0_255 regex_ip regex_a regex_c regex_n opt  

	regex_dur="([0-9]+)"
	regex_hh="(([0-9])|([0-1][0-9])|([2][0-3]))"
	regex_mm="([0-5][0-9])"
	regex_time="($regex_hh[:]$regex_mm)"
	regex_0_255="(([0-9])|([1-9][0-9])|([1][0-9][0-9])|([2][0-4][0-9])|([2][5][0-5]))"
	regex_ip="(($regex_0_255[.]){3,3}$regex_0_255)"

	regex_a="^$regex_time[,]$regex_time$"
	regex_c="^($regex_time[,]){2,2}[35]$"
	regex_n="^($regex_time[,]){2,2}[35][,]$regex_dur[,]$regex_ip([+]$regex_ip){0,}$"


	# parse the parameters
	while getopts ":p:w:a:c:n:vm" opt; do
		
		case $opt in
			p)	echo "$OPTARG" | grep -E "^$regex_dur$" >/dev/null 
				if [ "$?" -eq "0" ] ; then
					I_POLL_INTERVAL="$OPTARG"
				else
					log_error "$LOGFILE" "Invalid parameter \"$OPTARG\" for option: -p. Should be a positive integer"
					return 1
				fi ;;
			w)	echo "$OPTARG" | grep -E "^$regex_dur$" >/dev/null 
				if [ "$?" -eq "0" ] ; then
					I_DELAY_PREVENT_SLEEP_AFTER_WAKE="$OPTARG"
				else
					log_error "$LOGFILE" "Invalid parameter \"$OPTARG\" for option: -w. Should be a positive integer"
					return 1
				fi ;;
			a)	echo "$OPTARG" | grep -E "$regex_a" >/dev/null
				if [ "$?" -eq "0" ] ; then
					I_CHECK_ALWAYS_ON="1"	
					I_BEG_ALWAYS_ON=`echo "$OPTARG" | cut -f1 -d,`			
					I_END_ALWAYS_ON=`echo "$OPTARG" | cut -f2 -d,`			
				else
					log_error "$LOGFILE" "Invalid parameter \"$OPTARG\" for option: -a. Should be \"hh:mm,hh:mm\""
					return 1
				fi ;;
			c)	echo "$OPTARG" | grep -E "$regex_c" >/dev/null
				if [ "$?" -eq "0" ] ; then
					I_CHECK_CURFEW_ACTIVE="1"	
					I_BEG_POLL_CURFEW=`echo "$OPTARG" | cut -f1 -d,`			
					I_END_POLL_CURFEW=`echo "$OPTARG" | cut -f2 -d,`			
					I_ACPI_STATE_CURFEW=`echo "$OPTARG" | cut -f3 -d,`			
				else
					log_error "$LOGFILE" "Invalid parameter \"$OPTARG\" for option: -c. Should be \"hh:mm,hh:mm,acpi_state\""
					return 1
				fi ;;
			n)	echo "$OPTARG" | grep -E "$regex_n" >/dev/null
				if [ "$?" -eq "0" ] ; then
					I_CHECK_NOONLINE_ACTIVE="1"	
					I_BEG_POLL_NOONLINE=`echo "$OPTARG" | cut -f1 -d,`			
					I_END_POLL_NOONLINE=`echo "$OPTARG" | cut -f2 -d,`			
					I_ACPI_STATE_NOONLINE=`echo "$OPTARG" | cut -f3 -d,`			
					I_DELAY_NOONLINE=`echo "$OPTARG" | cut -f4 -d,`			
					I_IP_ADDRS=`echo "$OPTARG" | cut -f5 -d, | sed 's/+/ /g'`
				else
					log_error "$LOGFILE" "Invalid parameter \"$OPTARG\" for option: -n. Should be \"hh:mm,hh:mm,acpi_state,delay,ips\""
					return 1
				fi ;;
			v)	I_VERBOSE=1 ;;
			m)	I_MAIL_ACPI_CHANGE=1 ;;
			\?)
				log_error "$LOGFILE" "Invalid option: -$OPTARG"
				return 1 ;;
                        :)
				log_error "$LOGFILE" "Option -$OPTARG requires an argument"
				return 1 ;;
                esac
        done

	# Remove the optional arguments parsed above.
	shift $((OPTIND-1))
	
	# Check if the number of mandatory parameters 
	# provided is as expected 
	if [ "$#" -ne "0" ]; then
		log_error "$LOGFILE" "No mandatory arguments should be provided"
		return 1
	fi

        return 0
}


################################## 
# Returns true if the current time is within the timeslot
# provided as parameter.
#
# Param 1: Start of the timeslot (format: "hh:mm")
# Param 2: End of the timeslot (format: "hh:mm"). If End=Beg, 
#	   the timeslot is considered to last the whole day.
# Return: 0 if the current time is within the timeslot 
################################## 
isInTimeSlot() {
	local startTime endTime nbSecInDay currentTimestamp startTimestamp endTimestamp
        
	startTime="$1"
        endTime="$2"

	nbSecInDay="86400"

	currentTimestamp=`$BIN_DATE +"%s"`
	startTimestamp=`$BIN_DATE -j -f "%H:%M:%S" "$startTime:00" +"%s"`
	endTimestamp=`$BIN_DATE -j -f "%H:%M:%S" "$endTime:00" +"%s"`

	if [ "$endTimestamp" -le "$startTimestamp" ]; then
		if [ "$currentTimestamp" -gt "$startTimestamp" ]; then
			endTimestamp=`expr $endTimestamp + $nbSecInDay`
		else
			startTimestamp=`expr $startTimestamp - $nbSecInDay`
		fi
	fi

	if [ "$currentTimestamp" -gt "$startTimestamp" -a "$currentTimestamp" -le "$endTimestamp" ]; then
		return 0
	else
		return 1
	fi
}


################################## 
# Request NAS to sleep if no script is running currently
#
# Param 1: ACPI state (one of 3,5)
#    - 3: Sleeping (Suspend to RAM)
#    - 5: Soft off
# Return: 0 if the the NAS could be shutdown 
################################## 
nasSleep() {
	local acpi_state msg

	acpi_state="$1"

        if ! is_any_script_running; then

                msg="Shutting down the system to save energy (ACPI state : S$acpi_state)"
                
		if [ $acpi_state -eq "5" ]; then	# Soft OFF
        
			log_info "$LOGFILE" "$msg"
			log_info "$ACPI_STATE_LOGFILE" "S$acpi_state"
        	
			if [ $I_MAIL_ACPI_CHANGE -eq "1" ]; then	
				get_log_entries_ts "$LOGFILE" "$START_TIMESTAMP" | sendMail "NAS going to sleep to save energy (ACPI state: S$acpi_state)"
			fi

			awake="0"
			$BIN_SHUTDOWN -p now "$msg"
	
		elif [ $acpi_state -eq "3" ]; then	# Suspend to RAM
	        	
			log_info "$LOGFILE" "$msg"
			log_info "$ACPI_STATE_LOGFILE" "S$acpi_state"
        
			if [ $I_MAIL_ACPI_CHANGE -eq "1" ]; then	
				get_log_entries_ts "$LOGFILE" "$START_TIMESTAMP" | sendMail "NAS going to sleep to save energy (ACPI state: S$acpi_state)"
			fi		

			awake="0"
			$BIN_ACPICONF -s 3	
		else
			log_error "$LOGFILE" "Shutdown not possible. ACPI state \"$acpi_state\" not supported"
			return 1
		fi	
		return 0
	else
		log_info "$LOGFILE" "Shutdown not possible. The following scripts are running: `get_list_of_running_scripts`"
		return 1
	fi
}




################################## 
# Main 
##################################
main() {
	local ts_last_online_device ts_wakeup in_always_on_timeslot curfew_sleep_request noonline_sleep_request \
		any_device_online delta_t awakefor
	
	# initialization of local variables
	ts_last_online_device=`$BIN_DATE +%s`	# Timestamp when the last other device was detected to be online
	ts_wakeup=`$BIN_DATE +%s`		# Timestamp when the NAS woke up last time
	in_always_on_timeslot="0"		# 1=We are currently in the always on timeslot, 0 otherwise 
	curfew_sleep_request="0"		# 1=Sleep requested by curfew check, 0 otherwise
	noonline_sleep_request="0"		# 1=Sleep requested by no-online check, 0 otherwise 

	# Remove any existing locks
	reset_locks

	# Parse the input parameters
	if ! parseInputParams $ARGUMENTS; then
		return 1
	fi

	# log the selected configuration
	log_info "$LOGFILE" "-------------------------------------"
	log_info "$LOGFILE" "Selected settings for \"$SCRIPT_NAME\":"
	printf '%-35s %s\n' "- VERBOSE:" "$I_VERBOSE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- MAIL ACPI STATE CHANGES:" "$I_MAIL_ACPI_CHANGE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- POLL_INTERVAL:" "$I_POLL_INTERVAL" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- DELAY_PREVENT_SLEEP_AFTER_WAKE:" "$I_DELAY_PREVENT_SLEEP_AFTER_WAKE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- CHECK_ALWAYS_ON:" "$I_CHECK_ALWAYS_ON" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- BEG_ALWAYS_ON:" "$I_BEG_ALWAYS_ON" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- END_ALWAYS_ON:" "$I_END_ALWAYS_ON" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- CHECK_CURFEW_ACTIVE:" "$I_CHECK_CURFEW_ACTIVE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- BEG_POLL_CURFEW:" "$I_BEG_POLL_CURFEW" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- END_POLL_CURFEW:" "$I_END_POLL_CURFEW" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- ACPI_STATE_CURFEW:" "$I_ACPI_STATE_CURFEW" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- CHECK_NOONLINE_ACTIVE:" "$I_CHECK_NOONLINE_ACTIVE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- BEG_POLL_NOONLINE:" "$I_BEG_POLL_NOONLINE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- END_POLL_NOONLINE:" "$I_END_POLL_NOONLINE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- ACPI_STATE_NOONLINE:" "$I_ACPI_STATE_NOONLINE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- DELAY_NOONLINE:" "$I_DELAY_NOONLINE" | log_info "$LOGFILE"
	printf '%-35s %s\n' "- IP_ADDRS:" "$I_IP_ADDRS" | log_info "$LOGFILE"


	# Loop until the NAS is switched off
	while true; do
		[ $I_VERBOSE -eq "1" ] && log_info "$LOGFILE" "-----------------"

		# If the NAS just woke up
		if [ $awake -eq "0" ]; then
			awake="1"
 			ts_wakeup=`$BIN_DATE +%s`       	
			ts_last_online_device=`$BIN_DATE +%s`

			log_info "$ACPI_STATE_LOGFILE" "S0"
			log_info "$LOGFILE" "NAS just woke up (S0). Preventing sleep during the next $I_DELAY_PREVENT_SLEEP_AFTER_WAKE s"
        
			if [ $I_MAIL_ACPI_CHANGE -eq "1" ]; then	
				get_log_entries_ts "$LOGFILE" "$START_TIMESTAMP" | sendMail "NAS just woke up (S0)"
			fi	
		fi

		# Check if in always_on timeslot 
		in_always_on_timeslot="0"
		if [ $I_CHECK_ALWAYS_ON -eq "1" ]; then
			if isInTimeSlot "$I_BEG_ALWAYS_ON" "$I_END_ALWAYS_ON"; then
				[ $I_VERBOSE -eq "1" ] && log_info "$LOGFILE" "In always_on timeslot: [ $I_BEG_ALWAYS_ON ; $I_END_ALWAYS_ON ]"
				in_always_on_timeslot="1"
			fi
		fi

		# Check if curfew is reached
		curfew_sleep_request="0"
		if [ $I_CHECK_CURFEW_ACTIVE -eq "1" ]; then
			if isInTimeSlot "$I_BEG_POLL_CURFEW" "$I_END_POLL_CURFEW"; then
				[ $I_VERBOSE -eq "1" ] && log_info "$LOGFILE" "In curfew timeslot: [ $I_BEG_POLL_CURFEW ; $I_END_POLL_CURFEW ]"
				curfew_sleep_request="1"
			fi
		fi

		# Check if no other devices are online for a certain duration
		noonline_sleep_request="0"	
		if [ $I_CHECK_NOONLINE_ACTIVE -eq "1" ]; then
		
			if isInTimeSlot "$I_BEG_POLL_NOONLINE" "$I_END_POLL_NOONLINE"; then

				[ $I_VERBOSE -eq "1" ] && log_info "$LOGFILE" "In timeslot for monitoring other devices [ $I_BEG_POLL_NOONLINE ; $I_END_POLL_NOONLINE ]"

				any_device_online="0"
				for ip_addr in $I_IP_ADDRS; do 	
					if $BIN_PING -c 1 -t 1 $ip_addr > /dev/null ; then
						any_device_online="1"
						[ $I_VERBOSE -eq "1" ] && log_info "$LOGFILE" "Online device detected: $ip_addr (skipping any other device)"
						break
					fi
				done

				if [ "$any_device_online" -eq "1" ]; then	
					ts_last_online_device=`$BIN_DATE +%s`
				else
					delta_t=$((`$BIN_DATE +%s`-$ts_last_online_device))
					[ $I_VERBOSE -eq "1" ] && log_info "$LOGFILE" "No devices online for $delta_t s"
					if [ "$delta_t" -gt "$I_DELAY_NOONLINE" ]; then
						noonline_sleep_request="1"	
					fi
				fi
			fi
		fi

		# Sleep if required, but never if: 
		# - We are in the always on timeslot
		# - If the NAS woke-up shortly 
		awakefor=$((`$BIN_DATE +"%s"`-$ts_wakeup))
		if [ $in_always_on_timeslot -eq "0" -a $awakefor -gt $I_DELAY_PREVENT_SLEEP_AFTER_WAKE ]; then
			if [ $curfew_sleep_request -eq "1" ]; then
				log_info "$LOGFILE" "Curfew: Sleep requested"
				prevent_scripts_to_start
				nasSleep $I_ACPI_STATE_CURFEW
 			elif [ $noonline_sleep_request -eq "1" ]; then
				log_info "$LOGFILE" "No other device online: sleep requested"
				prevent_scripts_to_start
				nasSleep $I_ACPI_STATE_NOONLINE
			else
				allow_scripts_to_start
			fi
		else
			allow_scripts_to_start
		fi

		# wait until next poll	
		sleep $I_POLL_INTERVAL
	done
}



if ! main; then
        # Return the log entries that have been logged during the current
        # execution of the script
        get_log_entries_ts "$LOGFILE" "$START_TIMESTAMP" | sendMail "Sleep management issue"
fi



