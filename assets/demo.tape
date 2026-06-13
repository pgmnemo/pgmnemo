# demo.tape — vhs script for pgmnemo outcome-learning demo GIF
# Renders: assets/demo.gif
# Run on host (requires vhs): vhs assets/demo.tape
#
# Prerequisites (before running vhs):
#   export PGDATABASE=pgmnemo PGUSER=postgres PGPASSWORD=pgmnemo
#   # PG 17 + pgmnemo >= 0.9.0 must be running at localhost:5432

Output assets/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 900
Set Height 500
Set Theme "Catppuccin Mocha"

# Show the command, pause for readability
Type "python examples/01_reinforce_ranking_flip.py"
Sleep 500ms
Enter
Sleep 6s

# Pause on the outcome summary
Sleep 3s
