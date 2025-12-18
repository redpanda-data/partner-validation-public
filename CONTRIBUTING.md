# Contributing to Redpanda Partner Validation

Thank you for your interest in contributing to Redpanda's partner validation project!

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a new branch for your changes
4. Make your changes
5. Test your changes thoroughly
6. Submit a pull request

## Branch Naming

Use descriptive branch names:
- `feature/partner-name-feature-description`
- `fix/partner-name-bug-description`
- `docs/description`

Examples:
- `feature/akamai-linode-helm-validation`
- `fix/akamai-linode-kubeconfig-path`

## Code Guidelines

### Security First

- **NEVER** commit credentials, API keys, or sensitive data
- Always use configuration files with `.example` suffix for templates
- Test that `.gitignore` properly excludes sensitive files
- Use environment variables for sensitive configuration

### Testing

- Test all validation scripts before submitting
- Include both success and failure scenarios
- Document any prerequisites or dependencies
- Clean up resources after testing

### Documentation

- Update README files when adding new features
- Include clear setup instructions
- Document any new dependencies or requirements
- Add examples where helpful

## Pull Request Process

1. **Update Documentation**: Ensure all README files are updated
2. **Update CHANGELOG**: Add an entry describing your changes
3. **Test Thoroughly**: Run all validation scripts in your changes
4. **Clean Commits**: Use clear, descriptive commit messages
5. **Review Ready**: Ensure your PR is ready for review before submitting

### Commit Message Format

```
Brief description of change

- Bullet point details if needed
- Additional context
```

## Adding New Partners

When adding validation for a new partner:

1. Create a new directory: `partner-name/`
2. Include a partner-specific README
3. Add validation scripts with clear naming
4. Document setup requirements
5. Include example configuration files (`.example` suffix)
6. Update the main README with partner information

## Code Review

All submissions require review before merging. Reviewers will check:
- Security considerations
- Code quality and clarity
- Documentation completeness
- Test coverage
- Adherence to guidelines

## Questions?

If you have questions about contributing:
- Open an issue for discussion
- Review existing issues and pull requests
- Contact the maintainers

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
