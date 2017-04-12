#!/bin/bash

# Configuration
POOLDIR="/var/lib/bareos/storage"
MYSQL_USER="bareos"
MYSQL_PASSWORD="xxx"

function print_usage() {
	echo "  -e";
	echo "     delete empty (JobBytes=0) jobs";
        echo "  -p";
        echo "     prune all volumes ";
        echo "  -t";
        echo "     update all volumes to \"actiononpurge=Truncate\"";
        echo "  -n";
        echo "     update all volumes to \"actiononpurge=None\"";
        echo "  -Dc";
        echo "     delete all jobs that have a copy job"
        echo "  -Do";
        echo "     delete obsolete volume files from the disk (those not listed in catalog)"
        echo "       NOTE: this operation can take several minutes to complete"
        echo "  -Dp";
        echo "     delete all purged volumes from Bacula catalog"
        echo "  -h";
        echo "     print this screen";
        echo ""
        exit 0
}

if [ $# -lt 1 ]; then
        print_usage
        exit 3
fi

update_volume() {

        BACULA_BATCH="$(mktemp)"

        echo ""
        echo "updating all volumes to \"actiononpurge=$1\"..."
        echo ""

        cd "$POOLDIR"
        for i in *; do
            echo "update volume=$i ActionOnPurge=$1" >> $BACULA_BATCH;
        done
        bconsole < $BACULA_BATCH | grep $1
        rm -f $BACULA_BATCH
}

del_empty() {
	BACULA_BATCH="$(mktemp)"
	
	echo ""
	echo "deleting all empty T/f status jobs..."
	echo ""
	
	while read jid; do
	  echo "delete jobid=$jid" >> $BACULA_BATCH;
	done < <(echo "select jobid from Job where JobBytes=0 and JobFiles=0 and (JobStatus='T' or JobStatus='f' or JobStatus='A' or JobStatus='E');" | mysql --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --batch --skip-column-names bareos)
	
	bconsole < $BACULA_BATCH 
	rm -f $BACULA_BATCH
}

del_copied_jobs() {
	BACULA_BATCH="$(mktemp)"
	
	echo ""
	echo "SELECT DISTINCT Job.PriorJobId AS JobId, Job.Job, Job.JobId AS CopyJobId, Media.MediaType FROM Job JOIN JobMedia USING (JobId) JOIN Media USING (MediaId) WHERE Job.Type = 'C' ORDER BY Job.PriorJobId DESC;" | mysql --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" -t bareos
        echo ""
        echo "This will delete jobs from the first column above."
        echo -n "Are you sure ? (yes|no): "
        read response
        if [ "$response" = "yes" ]; then
          while read jid; do
            echo "delete jobid=$jid" >> $BACULA_BATCH;
          done < <(echo "SELECT DISTINCT Job.PriorJobId AS JobId FROM Job JOIN JobMedia USING (JobId) JOIN Media USING (MediaId) WHERE Job.Type = 'C' ORDER BY Job.PriorJobId DESC;" | mysql --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --batch --skip-column-names bareos)
          bconsole <  $BACULA_BATCH
        fi
        rm -f $BACULA_BATCH
}

prune_all() {

        BACULA_BATCH="$(mktemp)"

        echo ""
        echo "pruning all volumes and let Bacula mark them as purged once the retention periods are expired..."
        echo ""

        cd "$POOLDIR"
        for i in *; do
            echo "prune volume=$i" >> $BACULA_BATCH;
            echo "yes" >> $BACULA_BATCH;
        done
        bconsole < $BACULA_BATCH | grep -i "marking it purged"
        rm -f $BACULA_BATCH
}

delete_obsolete_volumes() {

        VOLUMES_TO_DELETE="$(mktemp)"

        echo ""
        echo "searching for obsolete files on disk. These could be some old volumes deleted from catalog manually..."
        echo ""

        cd "$POOLDIR"
        for i in *; do
            echo "list volume=$i" | bconsole | if grep --quiet "No results to list"; then
                echo "$i is ready to be deleted"  
                echo "$POOLDIR/$i" >> $VOLUMES_TO_DELETE
            fi
        done

        # Check whether we have found some volumes(files) to delete
        if [ $(wc -l $VOLUMES_TO_DELETE | awk {'print $1'}) -gt 0 ]; then

                echo ""
                echo -n "Are you sure you want to delete these volumes(files) from the disk ? (yes|no): "
                read response

                if [ "$response" = "yes" ]; then
			while read I; do
                                rm -f "$I"
                        done < $VOLUMES_TO_DELETE

                        echo ""
                        echo "DONE: following files were deleted: "
                        cat $VOLUMES_TO_DELETE
                fi

        else
                echo "No volumes to delete found on disk"

        fi

        rm -f $VOLUMES_TO_DELETE

}

delete_purged_volumes() {

        echo ""
        echo "searching for all purged volumes to be deleted..."
        echo ""

        PURGED_VOLUMES=$(echo "list volumes" | bconsole | grep "Purged.*File" | awk {'print $4'})
        echo "$PURGED_VOLUMES"

        echo ""
        echo -n "Are you sure you want to delete all these purged volumes from Bacula catalog ? (yes|no): "
        read response

        cd "$POOLDIR"
        LOGFILE="/tmp/delete-purged-volumes.log"
        
        if [ "$response" = "yes" ]; then
                BACULA_BATCH="$(mktemp)"
                rm -f "$LOGFILE"
                echo "@output $LOGFILE" > $BACULA_BATCH
                echo "$PURGED_VOLUMES" | while read I; do
                        echo "delete volume=$I" >> $BACULA_BATCH
                        echo "yes" >> $BACULA_BATCH
                done

                bconsole < $BACULA_BATCH
                rm -f $BACULA_BATCH
                echo "Done. See the log file $LOGFILE"
        fi
}

# Parse parameters
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
                print_usage
                exit 0
                ;;
        -e)
        	shift
        	del_empty
        	exit 0
        	;;
        -p)
                shift
                prune_all
                exit 0
                ;;
        -t)
                shift
                update_volume Truncate
                exit 0
                ;;
        -n)
                shift
                update_volume None
                exit 0
                ;;
        -Dc)
                shift
                del_copied_jobs
                exit 0
                ;;
        -Do)
                shift
                delete_obsolete_volumes
                exit 0
                ;;
        -Dp)
                shift
                delete_purged_volumes
                exit 0
                ;;
        *)  echo "Unknown argument: $1"
            print_usage
            exit 3
            ;;
        esac
done
exit 1
