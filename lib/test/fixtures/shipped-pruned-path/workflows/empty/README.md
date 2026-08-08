The workflows/empty/ fixture directory is intentionally empty of *.yml: it drives the
lint refusal on a workflows source that yields no workflow at all. Git tracks no empty
directory, so this file is what keeps the directory in the index.
