# Use case

This container is using ubuntu and contains a checkout of os-autoinst
and openQA to be able to run tests in a container that is similar to 
travis-ci. This is of course overkill for simple tests, but proved
to be very useful for larger changes.

# Building it

To use this testing container, you first need to build it:

    cd docker/testing
    docker build -t ci .
    ... this will take a while
  
# Testing it

Now you can test it by running an interactive shell in it:

    docker run -ti ci bash
  
Once you exit it, the changes done to it will be lost. This is actually
a feature :)

# Using it for testing

Now if you want to run a test, you need to push the changes to a git (as the
container has no access to your file system this is the easiest way) - you
better know how to squash commits later on.

    docker run -t ci /test.sh https://github.com/coolo/openQA-1.git myexperiment t/ui/06-users.t

So my routine is this loop:

    edit source
    git commit -a -m "[ci skip] commit" && git push && above docker command
