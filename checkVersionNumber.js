const fs = require('fs')

const pluginFile = fs.readFileSync('Koha/Plugin/Com/PTFSEurope/BarclaycardPayments.pm', 'utf8')
const fileByLine = pluginFile.split(/\r?\n/);

let versionNumberIdentified
fileByLine.forEach((line, index)=> {
    if(line.includes("our $VERSION")){
        versionNumberIdentified = index
    }
});

if(!versionNumberIdentified) { return }
if(versionNumberIdentified) {
    const regex = /"(.*?)"/
    const findVersionNumber = regex.exec(fileByLine[versionNumberIdentified])
    const pluginVersion = findVersionNumber[1]
    console.log(`v${pluginVersion}`)
}


