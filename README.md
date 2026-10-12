# Action Models

this repo consists of SoTA (as of 2026 Oct) VLA / WAMs and their profiling scripts

clone this repo with `--recurse-submodules` to initialize all the nested submodules

or fetch the submodules afterwards by the following command

```bash
git submodule update --init --recursive
```

### Model Weights 

the default model weights are stored at /srv/models/
users of group `models` can access the directory as well as the model weights

```bash
# create a shared directory for model weights and set the permissions
sudo ./bootstrap-models.sh --apply
```

### Action Policy Server & Profiling Scripts

a shared `deploy/` directory among all models stores the scripts for launching and profiling the policy servers 
