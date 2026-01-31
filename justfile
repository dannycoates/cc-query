# Run type checking
typecheck:
    npm run typecheck

# Run tests
test:
    @test/test.sh

# Bump version (patch by default, or major|minor|patch)
bump type="patch":
    @scripts/bump.sh {{type}}
