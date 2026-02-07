import fs from 'node:fs';
import path from 'node:path';

const ensureDir = (dirPath) => {
    fs.mkdirSync(dirPath, { recursive: true });
};

export const writeIssueResults = (filePath, results) => {
    const absolutePath = path.isAbsolute(filePath)
        ? filePath
        : path.join(process.cwd(), filePath);

    ensureDir(path.dirname(absolutePath));

    const payload = {
        updatedAt: new Date().toISOString(),
        results
    };

    fs.writeFileSync(absolutePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
};
