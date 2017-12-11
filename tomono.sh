#!/bin/bash

# Merge multiple repositories into one big monorepo. Migrates every branch in
# every subrepo to the eponymous branch in the monorepo, with all files
# (including in the history) rewritten to live under a subdirectory.
#
# To use a separate temporary directory while migrating, set the GIT_TMPDIR
# envvar.
#
# To access the individual functions instead of executing main, source this
# script from bash instead of executing it.

${DEBUGSH:+set -x}
if [[ "$BASH_SOURCE" == "$0" ]]; then
    is_script=true
    set -eu -o pipefail
else
    is_script=false
fi

function read_repositories {
    sed -e 's/#.*//' | grep .
}

function remote-branches {
    git branch -r | grep "^  $1/" | sed -e "s_$1/__"
}

# Create a monorepository in a directory "core". Read repositories from STDIN:
# one line per repository, with two space separated values:
#
# 1. The (git cloneable) location of the repository
# 2. The name of the target directory in the core repository
function create-mono {

    ## Argument parsing magic
    ## monorepo url and name are positional, but "--continue" and "--subdir [dir]" can appear anywhere)
    POSITIONAL=()
    while [[ $# -gt 0 ]]
    do
        key="$1"
        case $key in
            --subdir)
            subdir="$2"
            shift # past argument
            shift # past value
            ;;
            --continue)
            CONTINUE=true
            shift # past argument
            ;;
            *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
        esac
    done
    set -- "${POSITIONAL[@]}" # restore positional parameters

    echo "mono-repo ssh url: " $1
    url=$1
    echo "mono-repo name: " $2
    MONOREPO_NAME=$2

    # Adding a trailing slash if subdir is set
    dir=${subdir:-""}
    if [ -n "$dir" ]; then
        dir="$dir/"
    fi

    # Pretty risky, check double-check!
    if [ ${CONTINUE:=false} == false ]; then
        if [[ -d "$MONOREPO_NAME" ]]; then
            echo "Target repository directory $MONOREPO_NAME already exists." >&2
            return 1
        fi
        mkdir "$MONOREPO_NAME"
        pushd "$MONOREPO_NAME"
        git init
        git remote add origin $url
    else
        if [[ -d "$MONOREPO_NAME" ]]; then
            rm -rf "$MONOREPO_NAME"
        fi
        git clone "$url"
        pushd "$MONOREPO_NAME"
    fi
    read_repositories | while read repo name; do
        if [[ -z "$name" ]]; then
            echo "pass REPOSITORY NAME pairs on stdin" >&2
            return 1
        fi
        echo "Merging in $repo.." >&2
        git remote add "$name" "$repo"
        git fetch -qa "$name"

        git checkout -q "$name"/master

        merged_branches=$(git branch -r --merged  | grep -v master || true )
        if [ "$merged_branches" ]; then
          echo "$merged_branches" | sed "s/$name\///" | xargs -n 1 git push --delete "$name"
        fi

        # Merge every branch from the sub repo into the mono repo, into a
        # branch of the same name (create one if it doesn't exist).
        remote-branches "$name" | while read branch; do
            if [[ $branch != *"bazel-mig-"* ]]; then    
                if git rev-parse -q --verify "$branch"; then
                    # Branch already exists, just check it out (and clean up the working dir)
                    git checkout -q "$branch"
                    git checkout -q -- .
                    git clean -f -d
                else
                    # Create a fresh branch with an empty root commit"
                    git checkout -q --orphan "$branch"
                    # The ignore unmatch is necessary when this was a fresh repo
                    git rm -rfq --ignore-unmatch .
                    git commit -q --allow-empty -m "Root commit for $branch branch"
                fi
                
                ####
                temp_branch="$name-$branch"
                git checkout -b "$temp_branch" "$name"/"$branch"
                git filter-branch -f --index-filter 'git ls-files -s | \
                                                     sed "s~\(	\)\(.*\)~\1'"$dir$name"'/\2~" | \
                                                     GIT_INDEX_FILE=$GIT_INDEX_FILE.new \
                                                     git update-index --index-info && \
                                                     mv "$GIT_INDEX_FILE.new" "$GIT_INDEX_FILE" || true' @
                git checkout -q "$branch"
                git merge -q "$temp_branch" --allow-unrelated-histories
                git branch -q -D "$temp_branch"
                ####
            fi
        done
                
        for tag in `git ls-remote --tags $name | cut -f2 | grep -v "\^{}$" | sed -E 's/.*(RC;.*)/\1/g'`; do
          if [[ $tag =~ (.*)RC\;\.\;(.*) ]]; then
            fixed_tag=`echo $tag | sed -E "s/RC;.;(.*)/RC;$name;\1/" `
            echo $tag '-->' $fixed_tag
            git tag $fixed_tag $tag
            git tag -d $tag
          elif [[ $tag =~ (.*)RC\;(.*)\;(.*) ]]; then
            fixed_tag=`echo $tag | sed -E "s/RC;(.*);(.*)/RC;$name\/\1;\2/" `
            echo $tag '-->' $fixed_tag
            git tag $fixed_tag $tag
            git tag -d $tag
          fi;
        done

        echo 'finished changing tags (not pushed yet)'
 
    done
    
    git checkout -q master
    git checkout -q .
    git push --all origin
    git push --tags
}

if [[ "$is_script" == "true" ]]; then
    create-mono $@
fi
