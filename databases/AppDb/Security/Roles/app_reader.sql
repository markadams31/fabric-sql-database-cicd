CREATE ROLE [app_reader];
GO
-- Grant to a role or an Entra group, not to an individual user; membership is how a person
-- or service principal gets access. (Team convention -- in Fabric's Entra model a managed
-- identity is indistinguishable from a person, so this can't be reliably checked at build.)
GRANT SELECT ON SCHEMA::[app] TO [app_reader];
