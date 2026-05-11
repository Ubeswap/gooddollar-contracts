import { decryptVars } from './encrypted-vars';

if (!process.argv.includes('compile')) {
  decryptVars(process.env);
}
