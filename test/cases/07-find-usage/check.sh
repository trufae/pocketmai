grep -q 'config.py' "$STDOUT" && grep -q 'server.py' "$STDOUT" && grep -q 'migrate.py' "$STDOUT" && grep -q 'test_config.py' "$STDOUT"
