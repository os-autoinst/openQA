# Common files for os-autoinst/os-autoinst and os-autoinst/openQA

This repository is to be used as a
[git-subrepo](https://github.com/ingydotnet/git-subrepo).


`git-subrepo` is available in the following repositories:

[![Packaging status](https://repology.org/badge/vertical-allrepos/git-subrepo.svg)](https://repology.org/project/git-subrepo/versions)

## Usage

### Clone

To use it in your repository, you would usually do something like this:

    % cd your-repo
    % git subrepo clone git@github.com:os-autoinst/os-autoinst-common.git ext/os-autoinst-common

This will automatically create a commit with information on what command
was used.

And then, if necessary, link files via symlinks to the places where you need
them.

The cloned repository files will be part of your actual repository, so anyone
cloning this repo will have the files automatically without needing to use
`git-subrepo` themselves.

`ext` is just a convention, you can clone it into any directory.

It's also possible to clone a branch (or a specific tag or sha):

    % git subrepo clone git@github.com:os-autoinst/os-autoinst-common.git \
        -b branchname ext/os-autoinst-common

After cloning, you should see a file `ext/os-autoinst-common/.gitrepo` with
information about the cloned commit.

### Pull

To get the latest changes, you can pull:

    % git subrepo pull ext/os-autoinst-common

If that doesn't work for whatever reason, you can also simply reclone it like
that:

    % git subrepo clone --force git@github.com:os-autoinst/os-autoinst-common.git ext/os-autoinst-common

### Making changes

If you make changes in the subrepo inside of your top repo, you can simply commit
them and then do:

    % git subrepo push ext/os-autoinst-common

## git-subrepo

You can find more information here:
* [Repository and usage](https://github.com/ingydotnet/git-subrepo)
* [A good comparison between subrepo, submodule and
  subtree](https://github.com/ingydotnet/git-subrepo/blob/master/Intro.pod)


## License

This project is licensed under the MIT license, see LICENSE file for details.
