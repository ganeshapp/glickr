# glickr
Media uploader to Github Repo Album

The idea is simple, it is a flutter mobile app that allows you to upload photos/videos to a github repo. 

1. The app will allow you to use github device flow oAuth to authenticate the user.
2. Once authenticated, the user will be allowed to select a repo to which he wants to upload the photos. 
3. The main screen will show all the photos and videos in the local device gallery. 
4. The user can select a few of them and create a new album. He can give the album a name and a description. The folder will be created in the repo with the name (converted to lowercase and spaces replaced with underscore). And the description will be added to a album.md file in the folder. 
5. The user can also select photos and add them to existing albums (aka exisitng folders). 
6. The user can see existing albums and edit the description (so the album.md file is updated). And can delete photos in that album or even the entire album. 
7. All these actions are done using the github api, so the device doesn't have to maintain the git repo locally. 
8. The app can cache the photos and videos, so that each time the user goes to some album, the github api doesn't like one by one download all the photos and videos. 
9. While uploading the photos and videos the user should have an option to use preset quality options (low, medium, high). The default should be medium. Where the photos and videos are compressed to a lower quality. We don't want to be uploading 50mb videos or like ultra high mb photos. 
11. While uploading the photos/videos the app should convert them to either jpg or mp4. So even if heic or png or avi or other formats are uploaded, it should always convert them to the 2 standard formats. 
12. The app should also rename the photos 001.xxx, 002.xxx, 0003.xxx etc. Where xxx can be jpg or mp4. So even if the user selects photos from their gallery with different names, it should rename them in like incremental numbers.
13. If new photos/videos are added to existing album, then it should take the max file name and increment one to it and store that photo/video.
14. It would also be great if the app allows users to optionallyadd specific description to each photo/video. And there can be a json file called album.json which has the photo/video file name and the description. If a video or photo is deleted, then the json should also be updated to remove that entry, because in future some other photo/video uploaded might get that file name. 